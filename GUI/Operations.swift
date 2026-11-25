import Foundation
import AppKit
import Darwin

func isShadowName(_ name: String) -> Bool { ["DJpg", "DRaw", "DJpeg", "DJPEG"].contains { name.hasPrefix($0) } }

struct PoolBatch: Codable, Identifiable {
    var id: String
    var photo: Photo
    var entries: [TrashEntry]
}
struct Project: Codable, Identifiable {
    var root: String
    var counts: [String: Int]
    var formats: [String: Int]
    var organized: Bool
    var updated: String
    var sizes: [String: Int64]? = nil
    var mediaCount: Int? = nil
    var projectDate: Date? = nil
    var count: Int { mediaCount ?? counts.values.reduce(0,+) }
    var id: String { root }
    var name: String { URL(fileURLWithPath: root).lastPathComponent }
}

enum ProjectSort: String, CaseIterable {
    case added = "添加顺序"
    case date = "项目日期与时间"
    case size = "项目大小"
    case name = "项目名称"

    func compare(_ lhs: Project, _ rhs: Project) -> ComparisonResult {
        switch self {
        case .added: return .orderedSame
        case .date: return compareValues(lhs.projectDate, rhs.projectDate)
        case .size: return compareValues(lhs.sizes?["project"], rhs.sizes?["project"])
        case .name: return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    func hasValue(_ project: Project) -> Bool {
        switch self {
        case .date: return project.projectDate != nil
        case .size: return project.sizes?["project"] != nil
        default: return true
        }
    }

    private func compareValues<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs, lhs != rhs else { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

// All filesystem mutations are serialized off the UI thread. Every pool move is journaled first.
enum FileActions {
    static let queue = DispatchQueue(label: "studio.filter.files", qos: .userInitiated)
    static func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "Filter", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func read<T: Decodable>(_ type: T.Type, _ url: URL, default fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func save<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    static func poolURL(_ root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(".nikonfilter_logs/pool.json") }
    static func poolDirectory(for path: String, root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0.hasPrefix(".") }), let index = parts.firstIndex(where: isShadowName) else { return nil }
        return prefix + parts[...index].joined(separator: "/")
    }
    static func shadowDestination(_ path: String, root: String, isRaw: Bool) throws -> URL {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/"), !file.path.dropFirst(base.path.count+1).split(separator: "/").dropLast().contains(where: { isShadowName(String($0)) }) else { throw failure("文件不在正式池中") }
        var parent = file.deletingLastPathComponent()
        while parent.path != base.path && parent.path.hasPrefix(base.path + "/") {
            let name = parent.lastPathComponent.lowercased()
            if name.hasPrefix("jpg") || name.hasPrefix("jpeg") || name.hasPrefix("raw") {
                let relative = String(file.path.dropFirst(parent.path.count + 1))
                return parent.deletingLastPathComponent().appendingPathComponent("D" + parent.lastPathComponent).appendingPathComponent(relative)
            }
            parent.deleteLastPathComponent()
        }
        return base.appendingPathComponent((isRaw ? "DRaw" : "DJpg") + base.lastPathComponent).appendingPathComponent(String(file.path.dropFirst(base.path.count + 1)))
    }
    static func unique(_ url: URL, reserved: Set<String>) -> URL {
        if !reserved.contains(url.path), !FileManager.default.fileExists(atPath: url.path) { return url }
        return url.deletingPathExtension().appendingPathExtension(UUID().uuidString + "." + url.pathExtension)
    }
    static func stage(_ photo: Photo, paths: [String], root: String) throws -> PoolBatch {
        let fm = FileManager.default
        var batch = PoolBatch(id: UUID().uuidString, photo: photo, entries: [])
        let journal = poolURL(root)
        var batches = try read([PoolBatch].self, journal, default: [])
        var reserved = Set(batches.flatMap { $0.entries.map(\.trash) })
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("文件已变化，请刷新后重试") }
            let destination = unique(try shadowDestination(path, root: root, isRaw: path == photo.raw), reserved: reserved)
            reserved.insert(destination.path)
            batch.entries.append(TrashEntry(original: path, trash: destination.path))
        }
        batches.append(batch)
        try save(batches, journal)
        var moved: [TrashEntry] = []
        do {
            for entry in batch.entries {
                try fm.createDirectory(atPath: URL(fileURLWithPath: entry.trash).deletingLastPathComponent().path, withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: entry.trash) else { throw failure("待删池目标已存在") }
                try fm.moveItem(atPath: entry.original, toPath: entry.trash)
                moved.append(entry)
            }
        } catch {
            for entry in moved.reversed() { try? fm.moveItem(atPath: entry.trash, toPath: entry.original) }
            // Retain recovery mapping if a rollback was interrupted.
            if !batch.entries.contains(where: { fm.fileExists(atPath: $0.trash) }) { batches.removeAll { $0.id == batch.id }; try save(batches, journal) }
            throw error
        }
        return batch
    }
    static func restorePool(_ ids: Set<String>, root: String) throws {
        try restorePool(root: root, ids: ids, paths: nil)
    }

    static func restorePool(paths: Set<String>, root: String) throws {
        try restorePool(root: root, ids: nil, paths: paths)
    }

    private static func restorePool(root: String, ids: Set<String>?, paths: Set<String>?) throws {
        let fm = FileManager.default, journal = poolURL(root)
        var batches = try read([PoolBatch].self, journal, default: [])
        func normalized(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let requested = Set((paths ?? []).map(normalized))
        var selected = batches.flatMap { batch in
            batch.entries.filter { ids?.contains(batch.id) == true || requested.contains(normalized($0.trash)) }
        }
        let base = URL(fileURLWithPath: root).standardizedFileURL
        let recorded = Set(selected.map { normalized($0.trash) })
        for path in (paths ?? []).sorted() where !recorded.contains(normalized(path)) {
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard source.path.hasPrefix(base.path+"/") else { throw failure("待删文件不在项目内：\(path)") }
            var parts = source.path.dropFirst(base.path.count+1).split(separator: "/").map(String.init)
            guard let folder = parts.indices.dropLast().first(where: { isShadowName(parts[$0]) }) else {
                throw failure("找不到待删文件的恢复目录：\(path)")
            }
            parts[folder].removeFirst()
            let destination = parts.reduce(base) { $0.appendingPathComponent($1) }
            selected.append(TrashEntry(original: destination.path, trash: path))
        }
        guard Set(selected.map(\.original)).count == selected.count else { throw failure("多份待删文件指向同一原路径，恢复已停止。") }
        let realBase = base.resolvingSymlinksInPath().path+"/"
        for entry in selected {
            let source = URL(fileURLWithPath: entry.trash), destination = URL(fileURLWithPath: entry.original)
            let sourceInProject = source.deletingLastPathComponent().resolvingSymlinksInPath().path+"/"
            let destinationInProject = destination.deletingLastPathComponent().resolvingSymlinksInPath().path+"/"
            guard sourceInProject.hasPrefix(realBase), destinationInProject.hasPrefix(realBase),
                  (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw failure("恢复路径超出项目目录或为符号链接。")
            }
            let staged = fm.fileExists(atPath: entry.trash), original = fm.fileExists(atPath: entry.original)
            if !staged && !original { throw failure("待删文件已被删除或移动，请先撤回删除：\(entry.trash)") }
            if staged && original { throw failure("原路径已有文件，恢复已停止以避免覆盖：\(entry.original)") }
        }
        for entry in selected {
            if fm.fileExists(atPath: entry.trash) {
                try fm.createDirectory(at: URL(fileURLWithPath: entry.original).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(atPath: entry.trash, toPath: entry.original)
            }
            if let index = batches.firstIndex(where: { $0.entries.contains(where: { $0.trash == entry.trash }) }) {
                batches[index].entries.removeAll { $0.trash == entry.trash }
                batches.removeAll { $0.entries.isEmpty }
                try save(batches, journal)
            }
        }
    }
    static func trash(_ paths: [String], journal: URL, poolRoot: String? = nil) throws -> Int {
        func validatePoolDirectory(_ path: String, root: String) throws {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard poolDirectory(for: path, root: root) == path,
                  properties.isDirectory == true, properties.isSymbolicLink != true,
                  let resolved = realpath(path, nil) else {
                throw failure("待删池目录已经变化，请刷新后重试：\(path)")
            }
            defer { free(resolved) }
            guard String(cString: resolved) == path else { throw failure("待删池目录已经变化，请刷新后重试：\(path)") }
        }
        if let poolRoot {
            for path in paths { try validatePoolDirectory(path, root: poolRoot) }
        }
        var batches = try read([[TrashEntry]].self, journal, default: [])
        if poolRoot != nil { try save(batches, journal) }
        batches.append([])
        var count = 0
        for path in paths {
            if let poolRoot { try validatePoolDirectory(path, root: poolRoot) }
            guard FileManager.default.fileExists(atPath: path) else { throw failure("文件已被移动，请刷新：\(path)") }
            var result: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            guard let target = result?.path else { throw failure("系统未返回废纸篓位置") }
            batches[batches.count-1].append(TrashEntry(original: path, trash: target))
            try save(batches, journal)
            count += 1
        }
        return count
    }
    static func restoreTrash(journal: URL) throws {
        var batches = try read([[TrashEntry]].self, journal, default: [])
        guard let batch = batches.last else { return }
        for entry in batch {
            guard !FileManager.default.fileExists(atPath: entry.original) else { throw failure("原路径已有文件，无法覆盖：\(entry.original)") }
        }
        for entry in batch {
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: entry.original).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: entry.trash, toPath: entry.original)
            batches[batches.count-1].removeAll { $0.original == entry.original }
            try save(batches, journal)
        }
        batches.removeLast(); try save(batches, journal)
    }
}

func byteText(_ bytes: Int64) -> String { bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
