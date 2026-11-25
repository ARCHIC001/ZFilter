import SwiftUI
import AppKit
import ImageIO

private enum AppArtwork {
    static let icon = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("AppIcon.png")) ?? NSImage()
}

struct FloatingGlass: ViewModifier {
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.22 : 0.65), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6).allowsHitTesting(false))
            .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 12, y: 5)
    }
}

struct Photo: Codable, Identifiable, Equatable {
    var jpeg: String
    var raw: String?
    var status: String
    var source: String
    var jpegBytes: Int64? = nil
    var rawBytes: Int64? = nil
    var id: String { jpeg.isEmpty ? raw ?? "" : jpeg }
    var name: String { URL(fileURLWithPath: id).lastPathComponent }
}
struct RunRecord: Codable, Identifiable {
    var id: String; var timestamp: String; var mode: String; var moved: Int; var path: String
}
struct Library: Codable {
    var rawPhotos: [Photo]?; var poolRawPhotos: [Photo]?
    var poolDirectories: [String]?
    var root: String; var pending: Int; var photos: [Photo]; var poolPhotos: [Photo]; var poolBatches: [PoolBatch]; var counts: [String: Int]; var sizes: [String: Int64]; var mediaCount: Int; var formats: [String: Int]; var preview: [String: Int]; var organized: Bool; var paired: Int; var orphanRaw: Int; var ambiguous: Int; var history: [RunRecord]
}
struct TrashEntry: Codable { var original: String; var trash: String }
struct PoolRemoval: Identifiable, Equatable {
    let root: String
    let directories: [String]
    var id: String { root }
}

enum ProjectReadState { case ready, loading, failed }

@MainActor final class Model: ObservableObject {
    @Published var root = ""
    @Published private(set) var projectReadState: ProjectReadState = .ready
    @Published var activePhotos: [Photo] = []
    @Published var activeRawPhotos: [Photo] = []
    @Published var poolPhotos: [Photo] = []
    @Published var poolRawPhotos: [Photo] = []
    @Published var poolBatches: [PoolBatch] = []
    @Published private(set) var poolDirectories: [String] = []
    @Published private(set) var removingPool = false
    @Published var showPool = false
    var poolRemoval: PoolRemoval? {
        guard page == 1, showPool, !working, !currentProjectOffline, !root.isEmpty, !poolDirectories.isEmpty else { return nil }
        return PoolRemoval(root: root, directories: poolDirectories)
    }
    var photos: [Photo] { visiblePhotos(pool: showPool) }
    func visiblePhotos(pool: Bool,scope: String? = nil) -> [Photo] {
        let rows = scopedPhotos(pool: pool, scope: scope)
        guard burstsCollapsed || !burstOverrides.isEmpty, !burstIDs.isEmpty else { return rows }
        let raw = (scope ?? deleteMode) == "仅 RAW"
        return BurstMetadata.collapsed(rows, ids: burstIDs, isCollapsed: isBurstCollapsed, preferred: { id in
            raw ? burstRepresentatives[id]?.raw : burstRepresentatives[id]?.jpeg
        }) { raw ? $0.raw ?? "" : $0.jpeg }
    }
    func scopedPhotos(pool: Bool, scope: String? = nil) -> [Photo] {
        let scope = scope ?? deleteMode
        if scope == "仅 RAW" { return pool ? poolRawPhotos : activeRawPhotos }
        let jpeg = pool ? poolPhotos : activePhotos
        return scope == "JPEG + RAW" ? jpeg.filter { $0.raw != nil && $0.status == "已配对" } : jpeg
    }
    func displayPath(_ photo: Photo) -> String { deleteMode == "仅 RAW" ? photo.raw ?? "" : photo.jpeg }
    var currentPath: String? { current.map(displayPath) }
    var viewingRAW: Bool { deleteMode == "仅 RAW" }
    var viewingLabel: String { viewingRAW ? "RAW" : deleteMode == "仅 JPEG" ? "JPEG" : "JPEG + RAW · 已配对" }
    @Published var history: [RunRecord] = []
    @Published var index = 0
    @Published var page = 0
    @Published var mode = "normal"
    @Published var travel = false
    @Published var dry = false
    @Published var rules: Set<String> = ["1", "2", "3", "4"]
    @Published var preview: [String: Int] = [:]
    @Published var counts: [String: Int] = [:]
    @Published var sizes: [String: Int64] = [:]
    @Published var mediaCount = 0
    @Published var formats: [String: Int] = [:]
    @Published var organized = false
    @Published var pendingFiles = 0
    @Published var busy = false
    @Published var selectingFolder = false
    @Published var pending = 0
    var working: Bool { busy || pending > 0 }
    @Published var progress: Double = 0
    @Published var status = "点击 +，创建一个影像项目。"
    @Published var error: String?
    @Published var exif = false
    @Published var immersive = false
    @Published var collapsed = false
    @Published private(set) var appearance = FilterAppearance.system {
        didSet { preferences.set(appearance.rawValue, forKey: "filterAppearance") }
    }
    @Published var deleteMode = "JPEG + RAW" { didSet {
        guard oldValue != deleteMode else { return }
        let old = visiblePhotos(pool: showPool,scope: oldValue)
        let previous = old.indices.contains(index) ? old[index] : nil
        preferences.set(deleteMode,forKey: "deleteMode")
        index = previous.flatMap { p in photos.firstIndex { $0.id == p.id || (p.raw != nil && $0.raw == p.raw) } } ?? 0
        filmstripDepartures = []; prefetch()
    } }
    @Published var focusTracking = false
    @Published var showsFocusBox = false { didSet { preferences.set(showsFocusBox, forKey: "showsFocusBox") } }
    @Published var viewportLabel = "适应窗口"
    @Published var filmstripVisible = true
    @Published var filmstripDepartures: [FilmstripDeparture] = []
    @Published private(set) var burstsCollapsed = false
    @Published private(set) var scanningBursts = false
    @Published private(set) var hasScannedBursts = false
    @Published private(set) var burstIDs: [String: BurstID] = [:]
    @Published private var burstOverrides = Set<BurstID>()
    private var burstRepresentatives: [BurstID: Photo] = [:]
    private var burstScan: Task<[String: BurstID], Never>?
    private var burstScanID = UUID()
    private var scannedBurstPaths = Set<String>()
    @Published var paired = 0
    @Published var orphanRaw = 0
    @Published var ambiguous = 0
    @Published var projects: [Project] = []
    @Published var projectSort: ProjectSort = .added { didSet { preferences.set(projectSort.rawValue, forKey: "projectSort") } }
    @Published var projectSortDescending = false { didSet { preferences.set(projectSortDescending, forKey: "projectSortDescending") } }
    @Published var pinnedProjects: [String] = []
    @Published var connections: [String: ProjectConnection] = [:]
    @Published var trash: [[TrashEntry]] = []
    var departed = Set<String>()
    var poolDeparted = Set<String>()
    var needsRescan = false
    private var poolSelections: [Bool: String] = [:]
    let preferences: UserDefaults
    var keyMonitor: Any?
    var bridgeOverrideForTests: String?
    var previewTask: Task<Void, Never>?
    var connectionTimer: Timer?
    var connectionObservers: [(NotificationCenter,NSObjectProtocol)] = []
    var connectionProbes: [String: UUID] = [:]
    var connectionProbe: (String) -> Bool = { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path,isDirectory: &directory) && directory.boolValue && FileManager.default.isReadableFile(atPath: path)
    }
    let journal: URL
    var current: Photo? { photos.indices.contains(index) ? photos[index] : nil }
    var currentProjectOffline: Bool { connections[root] == .offline }
    var displayedProjects: [Project] {
        let pinned = Set(pinnedProjects)
        let ordinary = projects.enumerated().filter { !pinned.contains($0.element.root) }.sorted { lhs, rhs in
            let left = projectSort.hasValue(lhs.element), right = projectSort.hasValue(rhs.element)
            if left != right { return left }
            let comparison = projectSort.compare(lhs.element, rhs.element)
            if comparison == .orderedSame { return projectSortDescending ? lhs.offset > rhs.offset : lhs.offset < rhs.offset }
            return comparison == (projectSortDescending ? .orderedDescending : .orderedAscending)
        }.map(\.element)
        return pinnedProjects.compactMap { path in projects.first { $0.root == path } } + ordinary
    }
    init(preferences: UserDefaults = .standard, journal: URL? = nil) {
        self.preferences = preferences
        // Keep the existing journal across the app's display-name change.
        self.journal = journal ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Filter/trash-history.json")
        collapsed = preferences.bool(forKey: "sidebarCollapsed")
        appearance = FilterAppearance(rawValue: preferences.string(forKey: "filterAppearance") ?? "") ?? .system
        showsFocusBox = preferences.bool(forKey: "showsFocusBox")
        projectSort = ProjectSort(rawValue: preferences.string(forKey: "projectSort") ?? "") ?? .added
        projectSortDescending = preferences.bool(forKey: "projectSortDescending")
        filmstripVisible = preferences.object(forKey: "filmstripVisible") as? Bool ?? true
        if let saved = preferences.string(forKey: "deleteMode"),["仅 JPEG","仅 RAW","JPEG + RAW"].contains(saved) { deleteMode = saved }
        trash = (try? FileActions.read([[TrashEntry]].self, self.journal, default: [])) ?? []
        if let data = preferences.data(forKey: "projects"), let saved = try? JSONDecoder().decode([Project].self, from: data) { projects = saved }
        else { projects = (preferences.stringArray(forKey: "recentFolders") ?? []).map { Project(root: $0, counts: [:], formats: [:], organized: false, updated: "") } }
        pinnedProjects = (preferences.stringArray(forKey: "pinnedProjects") ?? []).filter { path in projects.contains { $0.root == path } }
    }
    deinit { connectionTimer?.invalidate(); connectionObservers.forEach { $0.0.removeObserver($0.1) } }
    func startProjectMonitoring() {
        guard connectionTimer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification,NSWorkspace.didRenameVolumeNotification,NSWorkspace.didWakeNotification] {
            let token = workspace.addObserver(forName: name,object: nil,queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == NSWorkspace.didUnmountNotification,let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.markVolumeOffline(volume) }
                    else { self?.refreshProjectConnections() }
                }
            }
            connectionObservers.append((workspace,token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didBecomeActiveNotification,object: nil,queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshProjectConnections() } }
        connectionObservers.append((center,token))
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 8,repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshProjectConnections() } }
        connectionTimer?.tolerance = 2
        refreshProjectConnections()
    }
    func stopProjectMonitoring() {
        connectionTimer?.invalidate(); connectionTimer = nil
        connectionObservers.forEach { $0.0.removeObserver($0.1) }; connectionObservers = []; connectionProbes = [:]
    }
    func refreshProjectConnections(only path: String? = nil) {
        let roots = Set(projects.map(\.root))
        for key in Array(connections.keys) where !roots.contains(key) { connections.removeValue(forKey: key) }
        for project in projects where (path == nil || project.root == path) && connectionProbes[project.root] == nil {
            let root = project.root, token = UUID(), probe = connectionProbe
            connectionProbes[root] = token
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let online = probe(root)
                Task { @MainActor [weak self] in
                    guard let self,self.connectionProbes[root] == token,self.projects.contains(where: { $0.root == root }) else { return }
                    self.connectionProbes.removeValue(forKey: root)
                    let state: ProjectConnection = online ? .online : .offline
                    if self.connections[root] != state { self.connections[root] = state }
                }
            }
        }
    }
    func markVolumeOffline(_ volume: URL) {
        let base = volume.standardizedFileURL.path
        for project in projects where project.root == base || project.root.hasPrefix(base+"/") {
            connectionProbes.removeValue(forKey: project.root)
            if connections[project.root] != .offline { connections[project.root] = .offline }
        }
    }
    func toggleSidebar() { collapsed.toggle(); preferences.set(collapsed, forKey: "sidebarCollapsed") }
    func toggleAppearance(from scheme: ColorScheme) { appearance = scheme == .dark ? .light : .dark }
    func toggleFilmstrip() {
        filmstripVisible.toggle(); preferences.set(filmstripVisible, forKey: "filmstripVisible")
        if filmstripVisible { prefetch() } else { filmstripDepartures = [] }
    }
    func focusCurrent() { focusTracking = true; NotificationCenter.default.post(name: .filterFocusZoom, object: currentPath) }
    func fitCurrent() { focusTracking = false; NotificationCenter.default.post(name: .filterFitImage, object: currentPath) }
    func choose() {
        guard !working, !selectingFolder else { return }; selectingFolder = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择素材文件夹，创建或打开项目"
        panel.begin { [weak self] response in
            self?.selectingFolder = false
            if response == .OK, let url = panel.url { Task { @MainActor in self?.open(url.path) } }
        }
    }
    func open(_ path: String) {
        guard !working else { return }
        guard connections[path] != .offline else { error = "项目离线，请连接磁盘或恢复项目目录后重试。\n"+path; return }
        busy = true; projectReadState = .loading; status = "正在读取素材、统计格式并验证配对…"
        focusTracking = false; viewportLabel = "适应窗口"; filmstripDepartures = []; poolSelections = [:]; resetBursts()
        root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path; preview = [:]; activePhotos = []; activeRawPhotos = []; poolPhotos = []; poolRawPhotos = []; poolBatches = []; counts = [:]; sizes = [:]; mediaCount = 0; formats = [:]; history = []; index = 0; departed = []; poolDeparted = []; showPool = false; organized = false; pendingFiles = 0; error = nil; previewTask?.cancel()
        poolDirectories = []
        Task { await loadLibrary() }
    }
    func request(_ action: String, rootOverride: String? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let req: [String: Any] = ["action": action, "root": rootOverride ?? root, "mode": mode, "rules": Array(rules), "travel": travel, "dry": dry]
        let input = try JSONSerialization.data(withJSONObject: req)
        let script = bridgeOverrideForTests ?? Bundle.main.resourceURL!.appendingPathComponent("filter_bridge.py").path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script]
                    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                    try process.run()
                    let watchdog = timeout.map { seconds -> DispatchWorkItem in
                        let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+seconds, execute: item)
                        return item
                    }
                    defer { watchdog?.cancel() }
                    stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
                    var buffer = Data(); var final: [String: Any] = [:]
                    while true {
                        let data = stdout.fileHandleForReading.availableData
                        if data.isEmpty { break }; buffer.append(data)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                            if let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                if let value = obj["progress"] as? Double {
                                    let name = obj["name"] as? String ?? ""
                                    DispatchQueue.main.async { self.progress = value; self.status = "正在整理 · \(name)" }
                                } else { final = obj }
                            }
                        }
                    }
                    process.waitUntilExit()
                    if timeout != nil && process.terminationReason == .uncaughtSignal && process.terminationStatus == 15 {
                        throw FileActions.failure("目录读取超时，已保留上次统计。请检查磁盘连接或文件夹访问权限。")
                    }
                    if let message = final["error"] as? String { throw FileActions.failure(message) }
                    guard process.terminationStatus == 0, !final.isEmpty else {
                        throw FileActions.failure(String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "引擎启动失败")
                    }
                    continuation.resume(returning: final)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func apply(_ object: [String: Any]) throws {
        let lib = try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: object))
        let old = currentPath
        root = lib.root; activePhotos = lib.photos; activeRawPhotos = lib.rawPhotos ?? lib.photos.filter { $0.raw != nil }; poolPhotos = lib.poolPhotos; poolRawPhotos = lib.poolRawPhotos ?? lib.poolPhotos.filter { $0.raw != nil }; poolBatches = lib.poolBatches
        poolDirectories = lib.poolDirectories ?? []
        removeAssets(departed,pool: false); removeAssets(poolDeparted,pool: true)
        history = lib.history; paired = lib.paired; orphanRaw = lib.orphanRaw; ambiguous = lib.ambiguous
        counts = lib.counts; sizes = lib.sizes; mediaCount = lib.mediaCount; formats = lib.formats; organized = lib.organized; pendingFiles = lib.pending; preview = lib.preview
        index = old.flatMap { p in photos.firstIndex(where: { displayPath($0) == p }) } ?? min(index, max(0, photos.count-1))
        saveProject(); prefetch()
        if page == 1 || hasScannedBursts { scanBursts() }
        projectReadState = .ready
    }
    func saveProject() {
        guard !root.isEmpty else { return }
        let project = Project(root: root, counts: counts, formats: formats, organized: organized, updated: ISO8601DateFormatter().string(from: Date()), sizes: sizes, mediaCount: mediaCount, projectDate: projects.first { $0.root == root }?.projectDate)
        if let i = projects.firstIndex(where: { $0.root == root }) { projects[i] = project }
        else { projects.append(project) }
        if let data = try? JSONEncoder().encode(projects) { preferences.set(data, forKey: "projects") }
        if connectionTimer != nil && connections[root] == nil { refreshProjectConnections(only: root) }
    }
    func refreshProjects(only path: String? = nil) async {
        guard !working, !selectingFolder else { return }
        refreshProjectConnections(only: path)
        let targets = projects.filter { path == nil || $0.root == path }
        busy = true; status = "正在刷新项目统计…"
        defer { busy = false }
        var failures: [String] = []
        for project in targets {
            status = "正在刷新 · " + project.name
            do {
                let result = try await request("scan", rootOverride: project.root, timeout: 15)
                if project.root == root { try apply(result) }
                else {
                    let lib = try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: result))
                    let refreshed = Project(root: lib.root, counts: lib.counts, formats: lib.formats, organized: lib.organized, updated: ISO8601DateFormatter().string(from: Date()), sizes: lib.sizes, mediaCount: lib.mediaCount, projectDate: project.projectDate)
                    if let i = projects.firstIndex(where: { $0.root == project.root }) { projects[i] = refreshed }
                }
            } catch { failures.append(project.name + "：" + error.localizedDescription) }
        }
        if let data = try? JSONEncoder().encode(projects) { preferences.set(data, forKey: "projects") }
        status = "项目统计已刷新 · \(targets.count-failures.count) 个成功"
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func removeProject(_ path: String) {
        guard !working, !selectingFolder else { return }
        projects.removeAll { $0.root == path }
        pinnedProjects.removeAll { $0 == path }; preferences.set(pinnedProjects,forKey: "pinnedProjects")
        connections.removeValue(forKey: path); connectionProbes.removeValue(forKey: path)
        if let data = try? JSONEncoder().encode(projects) { preferences.set(data, forKey: "projects") }
        if path == root {
            resetBursts()
            previewTask?.cancel(); root = ""; projectReadState = .ready; activePhotos = []; activeRawPhotos = []; poolPhotos = []; poolRawPhotos = []; poolBatches = []; history = []
            poolDirectories = []
            counts = [:]; sizes = [:]; mediaCount = 0; formats = [:]; preview = [:]; index = 0; pendingFiles = 0; organized = false
            departed = []; poolDeparted = []; showPool = false; error = nil
            status = "已移除项目记录，素材和恢复日志保留在原文件夹。"
        }
    }
    func toggleProjectPin(_ path: String) {
        guard !working,projects.contains(where: { $0.root == path }) else { return }
        if pinnedProjects.contains(path) { pinnedProjects.removeAll { $0 == path } }
        else { pinnedProjects.insert(path,at: 0) }
        preferences.set(pinnedProjects,forKey: "pinnedProjects")
    }
    func setProjectDate(_ date: Date?, for path: String) {
        guard let index = projects.firstIndex(where: { $0.root == path }) else { return }
        projects[index].projectDate = date
        if let data = try? JSONEncoder().encode(projects) { preferences.set(data, forKey: "projects") }
    }
    func scan() async {
        guard !root.isEmpty, !working else { return }
        busy = true; status = "正在更新项目…"
        if projectReadState == .failed { projectReadState = .loading; error = nil }
        await loadLibrary()
    }
    func loadLibrary() async {
        defer { busy = false }
        do { try apply(await request("scan")); status = "\(activePhotos.count) 张正式池 JPEG · \(poolPhotos.count) 张待删 · \(paired) 对已验证" }
        catch {
            if projectReadState == .loading { projectReadState = .failed; status = "无法读取影像项目" }
            self.error = error.localizedDescription
        }
    }
    func schedulePreview() {
        previewTask?.cancel(); preview = [:]
        previewTask = Task { try? await Task.sleep(nanoseconds: 180_000_000); guard !Task.isCancelled else { return }; await preflight() }
    }
    func preflight() async {
        guard !root.isEmpty, !working else { return }
        busy = true; defer { busy = false }
        do { preview = try await request("preview").mapValues { $0 as? Int ?? 0 }; status = "预检查已更新 · 在下方确认整理" }
        catch { self.error = error.localizedDescription }
    }
    func run(_ undo: Bool = false) async {
        guard !root.isEmpty, !working else { return }
        busy = true; progress = 0; status = undo ? "正在撤销整理…" : "正在整理素材…"
        defer { busy = false }
        do {
            let result = try await request(undo ? "undo" : "run")
            if let library = result["library"] as? [String: Any] { try apply(library) }
            let n = result["result"] as? [String: Int] ?? [:]
            status = "\(undo ? "撤销完成" : dry ? "演练完成，文件未移动" : pendingFiles > 0 ? "本次规则已处理，仍有 \(pendingFiles) 个文件待整理" : "整理完成") · \(n[undo ? "reverted" : "moved"] ?? 0) 个文件 · 跳过 \(n["skipped"] ?? 0) · 错误 \(n["errors"] ?? 0)"
            progress = 1
            if (n["errors"] ?? 0) > 0 { error = "部分文件处理失败，请检查目录权限。\n" + status }
        } catch { self.error = error.localizedDescription }
    }
    func prefetch() {
        let rows = photos
        let nearby = [index,index+1,index-1].filter { rows.indices.contains($0) }
        ImageStore.shared.cancelPending(except: Set(nearby.map { displayPath(rows[$0]) }))
        for i in nearby { ImageStore.shared.load(displayPath(rows[i]), prefetch: i != index) }
        if filmstripVisible {
            for entry in filmstripEntries(rows, index: index,raw: viewingRAW) { ThumbnailStore.shared.load(entry.id, prefetch: entry.index != index) }
        }
    }
    func step(_ delta: Int) { guard !photos.isEmpty else { return }; index = min(max(0, index+delta), photos.count-1); prefetch() }
    func selectPhoto(_ path: String) { guard !busy, let next = photos.firstIndex(where: { displayPath($0) == path }) else { return }; index = next; prefetch() }
    func selectIndex(_ next: Int) { guard !busy,photos.indices.contains(next),index != next else { return }; index = next; prefetch() }
    func switchPool(_ pool: Bool) {
        guard !working, pool != showPool else { return }
        poolSelections[showPool] = currentPath
        filmstripDepartures = []
        showPool = pool
        index = poolSelections[pool].flatMap { path in photos.firstIndex { displayPath($0) == path } } ?? 0
        prefetch()
    }
    var burstGroups: [BurstID: [String]] {
        guard !burstIDs.isEmpty else { return [:] }
        return scopedPhotos(pool: showPool).reduce(into: [:]) { groups, photo in
            let path = displayPath(photo)
            if let id = burstIDs[path] { groups[id, default: []].append(path) }
        }
    }
    func isBurstCollapsed(_ id: BurstID) -> Bool { burstsCollapsed != burstOverrides.contains(id) }
    func toggleBurst(_ path: String) -> Bool {
        guard !working, !currentProjectOffline, let id = burstIDs[path] else { return false }
        let members = scopedPhotos(pool: showPool).filter { burstIDs[displayPath($0)] == id }
        guard members.count > 1, let clicked = members.first(where: { displayPath($0) == path }) else { return false }
        let selection = currentPath
        if !isBurstCollapsed(id) {
            burstRepresentatives[id] = selection.flatMap { burstIDs[$0] } == id ? current : clicked
        }
        if burstOverrides.contains(id) { burstOverrides.remove(id) } else { burstOverrides.insert(id) }
        restoreBurstSelection(selection)
        return true
    }
    func toggleBursts() {
        guard !working, !scanningBursts, !root.isEmpty, !currentProjectOffline else { return }
        if hasScannedBursts { setBurstsCollapsed(!burstsCollapsed) }
        else { scanBursts(collapseOnFinish: true) }
    }
    func prepareBursts() {
        guard !root.isEmpty, !busy, !scanningBursts, !hasScannedBursts, !currentProjectOffline else { return }
        scanBursts()
    }
    private func setBurstsCollapsed(_ collapsed: Bool) {
        let path = currentPath
        if collapsed, let id = path.flatMap({ burstIDs[$0] }) { burstRepresentatives[id] = current }
        burstsCollapsed = collapsed
        burstOverrides.removeAll()
        restoreBurstSelection(path)
    }
    private func restoreBurstSelection(_ path: String?) {
        let rows = photos
        index = path.flatMap { target in rows.firstIndex { displayPath($0) == target } } ?? min(index, max(0, rows.count-1))
        prefetch()
    }
    private func resetBursts() {
        burstScan?.cancel(); burstScanID = UUID()
        burstIDs = [:]; burstsCollapsed = false; hasScannedBursts = false; scanningBursts = false
        scannedBurstPaths = []
        burstOverrides.removeAll(); burstRepresentatives.removeAll()
    }
    private func scanBursts(collapseOnFinish: Bool = false) {
        let rows = activePhotos + activeRawPhotos + poolPhotos + poolRawPhotos
        let paths = Set(rows.flatMap { [$0.jpeg, $0.raw ?? ""] }.filter { !$0.isEmpty }).subtracting(scannedBurstPaths)
        guard !paths.isEmpty else { return }
        let token = UUID(); burstScanID = token
        burstScan?.cancel(); scanningBursts = true
        let task = Task.detached(priority: .utility) {
            var result: [String: BurstID] = [:]
            for path in paths {
                if Task.isCancelled { break }
                if let burst = BurstMetadata.read(path) { result[path] = burst }
            }
            return result
        }
        burstScan = task
        Task {
            let result = await task.value
            guard self.burstScanID == token else { return }
            let path = currentPath
            burstIDs.merge(result) { _, new in new }
            scannedBurstPaths.formUnion(paths)
            scanningBursts = false; hasScannedBursts = true
            if collapseOnFinish { setBurstsCollapsed(true) }
            else { restoreBurstSelection(path) }
        }
    }
    func removeAssets(_ paths: Set<String>,pool: Bool) {
        func removing(_ rows: [Photo],raw: Bool) -> [Photo] {
            rows.compactMap { original in
                var p = original
                if paths.contains(p.jpeg) { p.jpeg = "" }
                if let r = p.raw,paths.contains(r) { p.raw = nil }
                guard raw ? p.raw != nil : !p.jpeg.isEmpty else { return nil }
                if p.jpeg.isEmpty || p.raw == nil { p.status = raw ? "仅 RAW" : "仅 JPEG"; p.source = "" }
                return p
            }
        }
        if pool { poolPhotos = removing(poolPhotos,raw: false); poolRawPhotos = removing(poolRawPhotos,raw: true) }
        else { activePhotos = removing(activePhotos,raw: false); activeRawPhotos = removing(activeRawPhotos,raw: true) }
    }
    func selectedPaths(_ photo: Photo) -> [String] {
        if viewingRAW { return [photo.raw].compactMap { $0 } }
        return deleteMode == "仅 JPEG" ? [photo.jpeg] : [photo.jpeg,photo.raw].compactMap { $0 }.filter { !$0.isEmpty }
    }
    func reject(stage: Bool) {
        guard let photo = current, !busy, page == 1 else { return }
        guard !currentProjectOffline else { error = "项目离线，连接磁盘后再执行选片操作。"; return }
        if stage && showPool { returnFromPool(); return }
        if deleteMode == "JPEG + RAW" && (photo.raw == nil || photo.status != "已配对") { error = "当前照片没有经过验证的配对，请刷新后重试。"; return }
        let paths = selectedPaths(photo), display = displayPath(photo)
        guard !paths.isEmpty else { status = "没有可处理的 RAW"; return }
        let projectRoot = root, trashJournal = journal
        let wasPool = showPool
        if filmstripVisible {
            let departure = FilmstripDeparture(path: display, image: ThumbnailStore.shared.cached(display), kind: stage ? .pool : .trash)
            filmstripDepartures.append(departure)
            Task { try? await Task.sleep(nanoseconds: 650_000_000); filmstripDepartures.removeAll { $0.id == departure.id } }
        }
        if wasPool { poolDeparted.formUnion(paths) } else { departed.formUnion(paths) }
        removeAssets(Set(paths),pool: wasPool); index = min(index, max(0, photos.count-1)); prefetch()
        pending += 1
        Task {
            defer {
                pending -= 1
                if pending == 0 && needsRescan { needsRescan = false; Task { await scan() } }
            }
            do {
                if stage {
                    let batch = try await FileActions.perform { try FileActions.stage(photo, paths: paths, root: projectRoot) }
                    poolBatches.append(batch)
                    let stagedDirectories = batch.entries.compactMap { FileActions.poolDirectory(for: $0.trash, root: projectRoot) }
                    poolDirectories = Set(poolDirectories + stagedDirectories).sorted()
                    var staged = photo
                    staged.jpeg = ""; staged.raw = nil
                    for entry in batch.entries {
                        if entry.original == photo.jpeg { staged.jpeg = entry.trash }
                        if entry.original == photo.raw { staged.raw = entry.trash }
                        burstIDs[entry.trash] = burstIDs[entry.original]
                        if scannedBurstPaths.contains(entry.original) { scannedBurstPaths.insert(entry.trash) }
                    }
                    staged.status = staged.jpeg.isEmpty ? "仅 RAW" : staged.raw == nil ? "仅 JPEG" : "已配对"
                    staged.source = "待删池 · 原始配对"
                    if !staged.jpeg.isEmpty { poolPhotos.append(staged) }; if staged.raw != nil { poolRawPhotos.append(staged) }
                    status = "已出局 → 待删池 · \(paths.count) 个文件 · 可随时恢复"
                } else {
                    let count = try await FileActions.perform { try FileActions.trash(paths, journal: trashJournal) }
                    trash = (try? FileActions.read([[TrashEntry]].self, journal, default: [])) ?? []
                    status = "已出局 → 废纸篓 · \(count) 个文件 · ⌘Z 撤回"
                }
                for path in paths {
                    let bytes = path == photo.jpeg ? (photo.jpegBytes ?? 0) : (photo.rawBytes ?? 0)
                    if !wasPool {
                        let category = path == photo.jpeg ? "jpg" : "raw"
                        sizes[category] = max(0, (sizes[category] ?? 0)-bytes)
                        sizes["active"] = max(0, (sizes["active"] ?? 0)-bytes)
                    }
                    if stage { sizes["pool"] = (sizes["pool"] ?? 0)+bytes }
                    else {
                        if wasPool { sizes["pool"] = max(0, (sizes["pool"] ?? 0)-bytes) }
                        sizes["project"] = max(0, (sizes["project"] ?? 0)-bytes)
                        sizes["media"] = max(0, (sizes["media"] ?? 0)-bytes)
                        mediaCount = max(0, mediaCount-1)
                    }
                    let key = path == photo.jpeg ? "jpg" : "raw"
                    if !wasPool { counts[key] = max(0, (counts[key] ?? 0)-1); let ext = URL(fileURLWithPath: path).pathExtension.uppercased(); formats[ext] = max(0, (formats[ext] ?? 0)-1) }
                }
                paired = activePhotos.filter { $0.raw != nil }.count; orphanRaw = activeRawPhotos.filter { $0.jpeg.isEmpty }.count; saveProject()
            } catch {
                departed.subtract(paths); poolDeparted.subtract(paths); self.error = error.localizedDescription
                // Rescan only on failure; normal culling never rescans the album.
                needsRescan = true
                trash = (try? FileActions.read([[TrashEntry]].self, journal, default: [])) ?? []
            }
        }
    }
    func remove() { reject(stage: false) }
    func removePool(_ confirmed: PoolRemoval) async {
        guard poolRemoval == confirmed else {
            error = "待删池已经变化，请重新确认。"
            return
        }
        busy = true; removingPool = true
        defer { removingPool = false }
        let result: Result<Int, Error>
        do {
            let log = journal
            result = .success(try await FileActions.perform {
                try FileActions.trash(confirmed.directories, journal: log, poolRoot: confirmed.root)
            })
        } catch { result = .failure(error) }
        trash = (try? FileActions.read([[TrashEntry]].self, journal, default: [])) ?? []
        poolDeparted = []; filmstripDepartures = []
        await loadLibrary()
        switch result {
        case .success(let count): status = "已将 \(count) 个待删池文件夹移入废纸篓 · ⌘Z 撤回"
        case .failure(let failure): error = failure.localizedDescription
        }
    }
    func restore() {
        guard !working, !trash.isEmpty else { return }
        busy = true
        Task {
            do { let url = journal; try await FileActions.perform { try FileActions.restoreTrash(journal: url) }; departed = []; poolDeparted = [] }
            catch { self.error = error.localizedDescription }
            trash = (try? FileActions.read([[TrashEntry]].self, journal, default: [])) ?? []
            if root.isEmpty { busy = false } else { await loadLibrary() }
        }
    }
    @discardableResult func handleKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String? = nil) -> Bool {
        guard !busy, !selectingFolder, !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        if modifiers.contains(.command) { if code == 6 { restore(); return true }; return false }
        guard page == 1 else { return false }
        if ["、", "，", ","].contains(characters ?? "") {
            fitCurrent(); return true
        }
        switch code {
        case 29, 82, 31: focusCurrent()
        case 43, 42, 95: fitCurrent()
        case 123, 0: step(-1)
        case 124, 2: step(1)
        case 51, 117, 1: remove()
        case 13: reject(stage: true)
        case 48: immersive.toggle()
        case 53: immersive = false
        case 34: exif.toggle()
        case 17: toggleFilmstrip()
        case 11: toggleBursts()
        case 3: showsFocusBox.toggle()
        default: return false
        }
        return true
    }
    func returnFromPool(all: Bool = false) {
        guard !working, !currentProjectOffline else { return }
        let ids = Set(poolBatches.map(\.id))
        let paths = current.map { Set(selectedPaths($0)) } ?? []
        guard all ? !ids.isEmpty : showPool && !paths.isEmpty else { return }
        let projectRoot = root
        busy = true
        Task {
            do {
                try await FileActions.perform {
                    if all { try FileActions.restorePool(ids, root: projectRoot) }
                    else { try FileActions.restorePool(paths: paths, root: projectRoot) }
                }
                departed = []; poolDeparted = []
            }
            catch { self.error = error.localizedDescription }
            await loadLibrary()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmRun = false
    @State private var editingProject: Project?
    @State private var editedDate = Date()
    @State private var confirmUndo = false
    @State private var deletingPool: PoolRemoval?
    var accent: Color { Color(nsColor: FilterPalette.blue.accent(dark: colorScheme == .dark)) }
    var accentInk: Color { FilterPalette.blue.ink(dark: colorScheme == .dark) }
    var body: some View {
        HStack(spacing: 0) {
            if !m.immersive { sidebar.frame(width: m.collapsed ? 48 : 238).padding(14) }
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if m.page == 1 { viewer } else if m.page == 2 { records } else { organizer }
            }.clipShape(RoundedRectangle(cornerRadius: 14)).padding(.vertical, 12).padding(.trailing, 12).padding(.leading, m.immersive ? 12 : 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color.primary)
        .buttonBorderShape(.capsule)
        .foregroundStyle(.primary)
        .frame(minWidth: 1000, minHeight: 680)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if m.page != 1 {
                HStack { Circle().fill(m.working ? FilterPalette.orange.color : accent).frame(width: 5, height: 5); Text(m.status).font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 24).padding(.bottom, 10)
            }
        }
        .alert("ZFilter", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) { Button("好") { m.error = nil } } message: { Text(m.error ?? "") }
        .confirmationDialog(m.dry ? "开始演练？文件不会移动。" : "整理所选目录及其子文件夹中的素材？输出将写入：\n" + m.root + "\n可通过整理日志撤销。", isPresented: $confirmRun, titleVisibility: .visible) { Button(m.dry ? "开始演练" : "开始整理") { Task { await m.run() } } }
        .confirmationDialog("撤销最近一次整理，将文件移回原目录？", isPresented: $confirmUndo, titleVisibility: .visible) { Button("撤销整理") { Task { await m.run(true) } } }
        .onChange(of: m.mode) { _, _ in m.schedulePreview() }.onChange(of: m.travel) { _, _ in m.schedulePreview() }.onChange(of: m.rules) { _, _ in m.schedulePreview() }
        .onChange(of: m.appearance, initial: true) { _, appearance in NSApp.appearance = appearance.native }
        .onAppear { installKeys() }
        .sheet(item: $editingProject) { project in
            VStack(alignment: .leading, spacing: 18) {
                Text(project.name).font(.headline)
                DatePicker("项目日期与时间", selection: $editedDate)
                HStack {
                    if project.projectDate != nil {
                        Button("清除日期") { m.setProjectDate(nil, for: project.root); editingProject = nil }
                    }
                    Spacer()
                    Button("取消") { editingProject = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") { m.setProjectDate(editedDate, for: project.root); editingProject = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 350)
        }
        .sheet(item: $deletingPool) { plan in
            VStack(alignment: .leading, spacing: 14) {
                Text("删除整个待删池？").font(.headline)
                Text(plan.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("以下 \(plan.directories.count) 个待删池文件夹及其中全部内容会移入系统废纸篓。可用 ⌘Z 撤回。")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(plan.directories, id: \.self) { path in
                            Label(String(path.dropFirst(plan.root.count + (plan.root.hasSuffix("/") ? 0 : 1))), systemImage: "folder")
                                .font(.callout).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 56, idealHeight: 95, maxHeight: 180)
                HStack {
                    Spacer()
                    Button("取消") { deletingPool = nil }.keyboardShortcut(.cancelAction)
                    Button("移入废纸篓", role: .destructive) {
                        deletingPool = nil
                        Task { await m.removePool(plan) }
                    }
                }
            }.padding(24).frame(width: 465)
        }
    }
    var sidebar: some View {
        Group { if m.collapsed { compactSidebar } else { expandedSidebar } }
    }
    var appearanceButton: some View {
        let size: CGFloat = m.collapsed ? 32 : 38
        let dark = colorScheme == .dark
        return Button { m.toggleAppearance(from: colorScheme) } label: {
            HStack(spacing: 8) {
                Image(nsImage: AppArtwork.icon).resizable().scaledToFit()
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: m.collapsed ? 9 : 11))
                if !m.collapsed { Text("ZFilter").font(.system(size: 24, weight: .semibold)) }
            }.frame(width: m.collapsed ? 44 : nil, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(dark ? "切换为浅色模式" : "切换为深色模式")
            .accessibilityLabel("切换 ZFilter 外观")
            .accessibilityValue(dark ? "深色模式" : "浅色模式")
    }
    var projectSortMenu: some View {
        Menu {
            Picker("排序依据", selection: $m.projectSort) {
                ForEach(ProjectSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("排序方向", selection: $m.projectSortDescending) {
                Text("正序").tag(false)
                Text("倒序").tag(true)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: m.collapsed ? 44 : 24, height: m.collapsed ? 36 : 24)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("排序影像项目").help("\(m.projectSort.rawValue) · \(m.projectSortDescending ? "倒序" : "正序")")
    }
    var compactSidebar: some View {
        VStack(alignment: .center,spacing: 16) {
            VStack(spacing: 2) {
                appearanceButton
                Button(action: m.toggleSidebar) { Image(systemName: "sidebar.left").frame(width: 44,height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("展开侧栏").accessibilityLabel("折叠或展开侧栏")
            }.padding(.top,8)
            VStack(spacing: 8) {
                nav("素材整理","square.stack.3d.up",0)
                nav("沉浸选片","photo.on.rectangle.angled",1)
                nav("操作记录","clock.arrow.circlepath",2)
            }.frame(width: 44)
            VStack(spacing: 4) {
                projectSortMenu
                Button { Task { await m.refreshProjects() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44,height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(m.working || m.projects.isEmpty).help("刷新影像项目统计").accessibilityLabel("刷新影像项目")
                Button(action: m.choose) { Image(systemName: "plus").frame(width: 44,height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(m.working).help("添加项目").accessibilityLabel("添加项目")
            }
            ScrollView {
                VStack(spacing: 8) { ForEach(m.displayedProjects) { project in projectRow(project) } }.frame(width: 44).frame(maxWidth: .infinity,alignment: .center)
            }.scrollIndicators(.hidden)
        }.frame(width: 48).frame(maxHeight: .infinity,alignment: .top)
    }
    var expandedSidebar: some View {
        let projectLayout = m.collapsed ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: m.collapsed ? 16 : 24) {
            HStack {
                appearanceButton
                Spacer()
                Button(action: m.toggleSidebar) { Image(systemName: m.collapsed ? "sidebar.left" : "sidebar.leading").frame(width: 24, height: 24) }.buttonStyle(.plain).foregroundStyle(.secondary).help(m.collapsed ? "展开侧栏" : "折叠为图标").accessibilityLabel("折叠或展开侧栏")
            }.padding(.top, 18)
            VStack(spacing: 8) {
                nav("素材整理", "square.stack.3d.up", 0)
                nav("沉浸选片", "photo.on.rectangle.angled", 1)
                nav("操作记录", "clock.arrow.circlepath", 2)
            }
            projectLayout {
                if !m.collapsed { Text("影像项目").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary); Spacer() }
                projectSortMenu
                Button { Task { await m.refreshProjects() } } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }.buttonStyle(.plain).disabled(m.working || m.projects.isEmpty).help("刷新影像项目统计").accessibilityLabel("刷新影像项目")
                Button(action: m.choose) { Image(systemName: "plus").frame(width: 24, height: 24) }.buttonStyle(.glass).buttonBorderShape(.circle).disabled(m.working).help("添加项目").accessibilityLabel("添加项目")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(m.displayedProjects) { project in projectRow(project) }
                }
            }
        }.padding(.horizontal, m.collapsed ? 0 : 12)
    }
    func projectRow(_ project: Project) -> some View {
        let connection = m.connections[project.root] ?? .checking
        let selected = project.root == m.root
        let pinned = m.pinnedProjects.contains(project.root)
        let colors: [Color] = pinned ? [FilterPalette.blue.color.opacity(0.12),FilterPalette.cyan.color.opacity(0.08)] : [.clear,.clear]
        let state = connection.label+(selected ? " · 当前项目" : "")+(pinned ? " · 已置顶" : "")
        let detail = project.name+" · "+state+"\n"+connection.detail+"\n"+project.root
        return Button { m.open(project.root) } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "folder.fill").foregroundStyle(selected ? accent : .secondary).frame(width: 24,height: 26)
                    ConnectionIndicator(state: connection).frame(width: 14,height: 14).offset(x: 4,y: 4)
                }
                if !m.collapsed {
                    VStack(alignment: .leading,spacing: 5) {
                        Text(project.name).font(.system(size: 12,weight: .medium)).lineLimit(1)
                        Text("\(project.count) 个素材 · \(project.sizes.map { byteText($0["project"] ?? 0) } ?? "体积待读取")").font(.system(size: 9)).foregroundStyle(.secondary)
                        if let date = project.projectDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9,weight: .medium)).foregroundStyle(.secondary) }
                }
            }.padding(m.collapsed ? 0 : 10).frame(width: m.collapsed ? 44 : nil,height: m.collapsed ? 44 : nil).frame(maxWidth: .infinity,alignment: m.collapsed ? .center : .leading)
                .contentShape(Rectangle())
                .background(LinearGradient(colors: colors,startPoint: .topLeading,endPoint: .bottomTrailing),in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(m.working).help(detail).accessibilityLabel("项目 "+project.name).accessibilityValue(state)
            .contextMenu {
                Button(pinned ? "取消置顶" : "置顶项目",systemImage: pinned ? "pin.slash" : "pin") { m.toggleProjectPin(project.root) }.disabled(m.working)
                Button("设置项目日期与时间…", systemImage: "calendar") {
                    editedDate = project.projectDate ?? Date()
                    editingProject = project
                }.disabled(m.working)
                Divider()
                Button("在 Finder 中显示",systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.root)]) }
                Button("刷新项目",systemImage: "arrow.clockwise") { Task { await m.refreshProjects(only: project.root) } }.disabled(m.working)
                Divider()
                Button("删除项目（保留素材）",systemImage: "trash",role: .destructive) { m.removeProject(project.root) }.disabled(m.working)
            }
    }
    func nav(_ title: String, _ icon: String, _ page: Int) -> some View {
        Button { m.page = page } label: {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 20); if !m.collapsed { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); if m.page == page { Circle().fill(accent).frame(width: 5, height: 5) } } }.padding(m.collapsed ? 0 : 13).frame(width: m.collapsed ? 44 : nil,height: m.collapsed ? 44 : nil).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Color.primary.opacity(m.page == page ? 0.055 : 0),in: RoundedRectangle(cornerRadius: 8)).help(title).accessibilityLabel(title)
    }
    var organizer: some View {
        Group {
            if m.root.isEmpty {
                VStack(spacing: 22) {
                    Text("添加影像项目").font(.system(size: 32, weight: .medium))
                    Text("选择文件夹，读取 JPEG、RAW 与视频").font(.system(size: 13)).foregroundStyle(.secondary)
                    Button(action: m.choose) { Image(systemName: "plus").font(.system(size: 30, weight: .light)).frame(width: 76, height: 76) }.buttonStyle(.glass).help("选择素材文件夹").accessibilityLabel("选择素材文件夹创建项目")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.projectReadState != .ready {
                projectReadPlaceholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { organizerContent }
        }
    }
    @ViewBuilder var projectReadPlaceholder: some View {
        if m.projectReadState == .loading {
            VStack(spacing: 14) {
                ProgressView().progressViewStyle(.circular).controlSize(.large).accessibilityHidden(true)
                Text("正在读取影像项目").font(.headline)
            }.padding(.horizontal, 28).padding(.vertical, 22)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.questionmark").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                Text("无法读取影像项目").font(.headline)
                Button("重试") { Task { await m.scan() } }.buttonStyle(.glass).disabled(m.working)
            }
        }
    }
    var organizerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack { VStack(alignment: .leading, spacing: 10) { Text(URL(fileURLWithPath: m.root).lastPathComponent).font(.system(size: 32, weight: .medium)); Text(m.pendingFiles > 0 ? "\(m.pendingFiles) 个文件待整理" : m.organized ? "当前目录无新增待整理素材" : "当前无需移动文件") .font(.system(size: 13)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "square.stack.3d.up.fill").font(.system(size: 40, weight: .light)).foregroundStyle(accent.opacity(0.7)) }
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("项目总占用").font(.system(size: 11)).foregroundStyle(.secondary); Text(byteText(m.sizes["project"] ?? 0)).font(.system(size: 25, weight: .medium, design: .rounded)) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) { Text("素材 \(byteText(m.sizes["media"] ?? 0)) · 待删池 \(byteText(m.sizes["pool"] ?? 0))"); Text("其他文件 \(byteText(m.sizes["other"] ?? 0)) · 按文件大小统计") }.font(.system(size: 11)).foregroundStyle(.secondary)
                    Button { Task { await m.scan() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).disabled(m.working).help("刷新当前项目体积与统计")
                }.padding(20).background(FilterPalette.blue.soft.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                Text(m.root).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("递归读取全部子文件夹；下列为正式池统计，待删池另计。整理输出位于所选目录内。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 16) { stat("JPEG", m.counts["jpg"] ?? 0, "photo", bytes: m.sizes["jpg"],hue: .green); stat("RAW", m.counts["raw"] ?? 0, "camera.aperture", bytes: m.sizes["raw"],hue: .purple); stat("视频 / RAW 视频", (m.counts["video"] ?? 0) + (m.counts["rawvideo"] ?? 0), "video", bytes: (m.sizes["video"] ?? 0)+(m.sizes["rawvideo"] ?? 0),hue: .orange); stat("已验证配对", m.paired, "link",hue: .cyan) }
                HStack(spacing: 10) { ForEach(m.formats.keys.sorted(), id: \.self) { key in Text("\(key)  \(m.formats[key] ?? 0)").font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 7).background(Color.primary.opacity(0.06), in: Capsule()) } }
                if m.organized {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("当前无新增待整理素材", systemImage: "checkmark.seal.fill").foregroundStyle(accent).font(.headline)
                        if let record = m.history.first { Text(record.mode + " · " + record.timestamp.replacingOccurrences(of: "T", with: "  ")).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Text("正式池 \(m.activePhotos.count) 张 JPEG · 待删池 \(m.poolPhotos.count) 张").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack { Button("开始选片") { m.page = 1 }.buttonStyle(.glassProminent).tint(accent); Button("查看操作记录") { m.page = 2 }.buttonStyle(.glass); Spacer(); Button("刷新统计") { Task { await m.scan() } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(24).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                }
                Group {
                VStack(alignment: .leading, spacing: 20) {
                    Text("整理方式").font(.system(size: 18, weight: .medium))
                    Picker("模式", selection: $m.mode) { Text("普通模式").tag("normal"); Text("RED 模式").tag("red"); Text("自定义规则").tag("custom") }.pickerStyle(.segmented)
                    Text(m.mode == "red" ? "JPEG / RAW 分离 · 普通视频归档 · NEV 改为 R3D · 代理与转码目录" : m.mode == "custom" ? "按需要启用规则；同时选择 4 和 5 时，RED 规则优先。" : "JPEG / RAW 分离 · 普通视频归档 · NEV 与同名 MP4 代理分类").font(.system(size: 12)).foregroundStyle(.secondary)
                    if m.mode == "custom" {
                        ForEach(Array(zip(["1", "2", "3", "4", "5"], ["JPEG 照片", "RAW 照片", "普通视频", "NEV 与代理", "RED / R3D 与代理"])), id: \.0) { key, title in Toggle("\(key) · \(title)", isOn: Binding(get: { m.rules.contains(key) }, set: { if $0 { m.rules.insert(key) } else { m.rules.remove(key) } })).toggleStyle(.checkbox) }
                    }
                    Divider().overlay(Color.primary.opacity(0.08))
                    Toggle(isOn: $m.travel) { VStack(alignment: .leading, spacing: 5) { Text("旅行模式").font(.system(size: 13, weight: .medium)); Text("按 EXIF 拍摄日期整理 JPEG 与 RAW；无日期素材保留在分类根目录。") .font(.system(size: 11)).foregroundStyle(.secondary) } }.toggleStyle(.switch)
                    Toggle(isOn: $m.dry) { VStack(alignment: .leading, spacing: 5) { Text("演练模式").font(.system(size: 13, weight: .medium)); Text("查看执行结果，不移动文件，不写入整理日志。") .font(.system(size: 11)).foregroundStyle(.secondary) } }.toggleStyle(.switch)
                }.padding(24).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18)).disabled(m.busy)
                if !m.preview.isEmpty {
                    VStack(alignment: .leading, spacing: 9) { Text("整理预览").font(.headline); Text("待检查文件 \(m.preview["total_scanned"] ?? 0) · 预计处理 \(planned) · 不支持 \(m.preview["unsupported"] ?? 0) · 按规则跳过 \(m.preview["will_skip_by_rule"] ?? 0)"); if m.travel { Text("日期分组 \(m.preview["travel_date_folders"] ?? 0) · 无日期 JPEG \(m.preview["travel_jpg_undated"] ?? 0) / RAW \(m.preview["travel_raw_undated"] ?? 0)") } }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { Task { await m.preflight() } } label: { Label("预检查", systemImage: "checkmark.shield").padding(6) }.buttonStyle(.glass)
                    Button { confirmRun = true } label: { Label(m.dry ? "开始演练" : "开始整理", systemImage: "arrow.right").padding(6) }.buttonStyle(.glassProminent).tint(accent).foregroundStyle(.black).disabled(m.preview.isEmpty || planned == 0 || (m.mode == "custom" && m.rules.isEmpty))
                    Spacer()
                    if !m.history.isEmpty { Button("撤销上次整理") { confirmUndo = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.disabled(m.working || m.root.isEmpty)
                }
                if m.busy { HStack { ProgressView().controlSize(.small); Text(m.status).font(.system(size: 11)) }; ProgressView(value: m.progress).tint(accent) }
            }.padding(36)
        }
    }
    var planned: Int { m.preview.filter { $0.key.hasPrefix("will_rule") }.values.reduce(0,+) }
    func stat(_ title: String, _ count: Int, _ icon: String, bytes: Int64? = nil, hue: FilterPalette = .blue) -> some View {
        VStack(alignment: .leading, spacing: 14) { HStack { Text(title).font(.system(size: 10,weight: .medium)).foregroundStyle(hue.ink(dark: colorScheme == .dark)); Spacer(); Image(systemName: icon).font(.system(size: 13)).foregroundStyle(hue.ink(dark: colorScheme == .dark)).frame(width: 28,height: 28).background(hue.color.opacity(0.13),in: RoundedRectangle(cornerRadius: 9)) }; Text("\(count)").font(.system(size: 29, weight: .light, design: .rounded)).monospacedDigit(); if let bytes { Text(byteText(bytes)).font(.system(size: 11)).foregroundStyle(.secondary) } else { Text(" ").font(.system(size: 11)) } }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color.primary.opacity(0.035),Color.primary.opacity(0.015)],startPoint: .topLeading,endPoint: .bottomTrailing),in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hue.color.opacity(0.13),lineWidth: 0.7))
    }
    func modeButton(_ title: String, _ value: String, _ hue: FilterPalette) -> some View {
        let selected = m.deleteMode == value
        let dark = colorScheme == .dark
        let color = hue.color, ink = hue.ink(dark: dark)
        return Button { m.deleteMode = value } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .semibold))
            }.foregroundStyle(selected || !dark ? ink : ink.opacity(0.65)).padding(.horizontal, 10).padding(.vertical, 10)
                .glassEffect(.regular.tint(color.opacity(selected ? 0.28 : 0.04)).interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(selected ? 0.85 : 0.18), lineWidth: selected ? 1.5 : 0.5))
                .shadow(color: color.opacity(selected ? 0.15 : 0),radius: 8,y: 3)
        }.buttonStyle(.plain).disabled(m.working).accessibilityLabel(value).accessibilityValue(selected ? "当前查看及删除范围" : "未选中").help(value == "仅 RAW" ? "查看 RAW 并仅处理 RAW" : value == "仅 JPEG" ? "查看 JPEG 并仅处理 JPEG" : "仅查看已配对的 JPEG，同时处理 JPEG 与 RAW")
    }
    var viewer: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider().opacity(0.5)
            HStack(alignment: .top,spacing: 12) {
                VStack(spacing: 12) {
                    ZStack {
                        Color(white: colorScheme == .dark ? 0.10 : 0.88)
                        if m.removingPool {
                            VStack(spacing: 12) { ProgressView(); Text("正在删除待删池…").font(.headline) }
                        } else if m.projectReadState != .ready {
                            projectReadPlaceholder
                        } else if let p = m.current {
                            ImageCanvas(path: m.displayPath(p),raw: m.viewingRAW ? nil : p.raw,focusTracking: m.focusTracking,showsFocusBox: m.showsFocusBox,onMessage: { m.status = $0 },onFocusTrackingChange: { if m.focusTracking != $0 { m.focusTracking = $0 } },onViewportChange: { if m.viewportLabel != $0 { m.viewportLabel = $0 } })
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36,weight: .light)).foregroundStyle(.secondary)
                                Text(m.root.isEmpty ? "打开影像项目" : m.deleteMode == "JPEG + RAW" ? "当前范围没有已配对的 JPEG" : m.viewingRAW ? "当前范围没有 RAW" : "当前范围没有 JPEG").font(.system(size: 20,weight: .medium))
                                if !m.root.isEmpty { Text("可在下方切换查看范围").font(.system(size: 12)).foregroundStyle(.secondary) }
                                Button("打开文件夹",action: m.choose).buttonStyle(.glass)
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08),lineWidth: 0.5).allowsHitTesting(false))
                        .frame(maxWidth: .infinity,maxHeight: .infinity)
                    if m.filmstripVisible && (!m.photos.isEmpty || !m.filmstripDepartures.isEmpty) { FilmstripBar().transition(.opacity) }
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
                if m.exif,let p = m.current { photoInspector(p).frame(width: 264).frame(maxHeight: .infinity).transition(.opacity) }
            }.padding(12).frame(maxWidth: .infinity,maxHeight: .infinity)
            if !m.root.isEmpty {
                Divider().opacity(0.5)
                viewerFooter
            }
        }.background(Color(nsColor: .windowBackgroundColor)).onAppear { m.prepareBursts() }
    }
    func photoInspector(_ p: Photo) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("照片信息").font(.system(size: 12,weight: .semibold)); Spacer()
                Button { m.exif = false } label: { Image(systemName: "xmark") }.buttonStyle(ViewerToolStyle()).accessibilityLabel("关闭照片信息")
            }.padding(.leading,14).padding(.trailing,5).padding(.vertical,3)
            Divider()
            ScrollView {
                VStack(alignment: .leading,spacing: 9) {
                    ExifRows(path: m.displayPath(p), companion: m.viewingRAW ? (p.jpeg.isEmpty ? nil : p.jpeg) : p.raw).id(m.displayPath(p))
                    HStack { Text("当前视图").foregroundStyle(.secondary); Spacer(); Text(m.viewportLabel) }.font(.system(size: 11))
                    Divider()
                    HStack { Text("文件与配对").font(.system(size: 11,weight: .semibold)); Spacer(); Text(m.showPool ? "待删池" : "正式池").font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.top,4)
                    HStack(spacing: 12) {
                        Label(p.jpeg.isEmpty ? "JPEG 未配对" : "JPEG 存在",systemImage: p.jpeg.isEmpty ? "minus.circle" : "checkmark.circle.fill").foregroundStyle((p.jpeg.isEmpty ? FilterPalette.yellow : .green).ink(dark: colorScheme == .dark))
                        Label(p.raw == nil ? "RAW 未配对" : "RAW 存在",systemImage: p.raw == nil ? "minus.circle" : "checkmark.circle.fill").foregroundStyle((p.raw == nil ? FilterPalette.yellow : .green).ink(dark: colorScheme == .dark))
                    }.font(.system(size: 10,weight: .medium))
                    fileSizeRow("JPEG 体积", present: !p.jpeg.isEmpty, bytes: p.jpegBytes)
                    fileSizeRow("RAW 体积", present: p.raw != nil, bytes: p.rawBytes)
                    HStack { Text("配对状态").foregroundStyle(.secondary); Spacer(); Text(p.status) }.font(.system(size: 11))
                    if !p.source.isEmpty { Text("验证依据 · " + p.source).font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text(m.viewingRAW ? (p.jpeg.isEmpty ? "此 RAW 没有经过验证的 JPEG 配对" : "JPEG · "+URL(fileURLWithPath: p.jpeg).lastPathComponent) : (p.raw.map { "RAW · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "此 JPEG 没有经过验证的 RAW 配对")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.displayPath(p))]) }.font(.system(size: 11)).buttonStyle(.plain)
                }.padding(12)
            }.scrollIndicators(.automatic)
        }.modifier(FloatingGlass(radius: 10)).accessibilityIdentifier("photoInspector")
    }
    private func fileSizeRow(_ title: String, present: Bool, bytes: Int64?) -> some View {
        let value = present ? bytes.map(byteText) ?? "未读取" : "无文件"
        let detail = present ? bytes.map { $0.formatted() + " 字节" } ?? value : value
        return HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 11)).help(detail)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(detail)
    }
    var viewerFooter: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    modeButton("仅 JPEG","仅 JPEG",.green)
                    modeButton("仅 RAW","仅 RAW",.yellow)
                    modeButton("JPEG+RAW","JPEG + RAW",.red)
                }
            }
            Spacer(minLength: 0)
            if m.showPool {
                Button { deletingPool = m.poolRemoval } label: {
                    Label("删除整个待删池", systemImage: "trash")
                        .foregroundStyle(FilterPalette.red.ink(dark: colorScheme == .dark))
                }.buttonStyle(.glass).disabled(m.poolRemoval == nil)
                    .help("移入当前项目的所有待删池文件夹 · 需要确认")
            }
            HStack(spacing: 2) {
                Button { m.step(-1) } label: { Image(systemName: "chevron.left") }.disabled(m.index == 0)
                Text("\(m.photos.isEmpty ? 0 : m.index+1) / \(m.photos.count)").font(.system(size: 11,design: .monospaced)).monospacedDigit().frame(minWidth: 58)
                Button { m.step(1) } label: { Image(systemName: "chevron.right") }.disabled(m.index >= m.photos.count-1)
                Divider().frame(height: 16).padding(.horizontal,5)
                Button { m.reject(stage: true) } label: { Image(systemName: m.showPool ? "tray.and.arrow.down" : "tray.and.arrow.up") }
                    .disabled(m.current == nil || m.currentProjectOffline || m.busy || (m.showPool && m.working))
                    .help(m.showPool ? "恢复到正式池 · W" : "移入待删池 · W")
                    .accessibilityLabel(m.showPool ? "恢复到正式池" : "移入待删池")
                Button { m.remove() } label: { Image(systemName: "trash") }.disabled(m.current == nil || m.currentProjectOffline || m.busy).help("移入废纸篓 · S / Delete")
                Button { m.restore() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(m.trash.isEmpty).help("撤回删除 · ⌘Z")
            }.buttonStyle(ViewerToolStyle())
        }.padding(.horizontal,12).padding(.vertical,9)
    }
    var viewerToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading,spacing: 5) {
                Text(m.currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "沉浸选片").font(.system(size: 14,weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text((m.currentProjectOffline ? "项目离线 · " : m.viewingLabel+" · ")+m.viewportLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        poolTab("正式池", count: m.scopedPhotos(pool: false).count, pool: false)
                        poolTab("待删池", count: m.scopedPhotos(pool: true).count, pool: true)
                    }.fixedSize(horizontal: true, vertical: false)
                        .padding(3).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9)).disabled(m.working)
                    HStack(spacing: 2) {
                        Button { m.focusCurrent() } label: { Image(systemName: "viewfinder") }.buttonStyle(ViewerToolStyle(active: m.focusTracking)).help("对焦点 / 中心兜底 100%，切图保持 · 0 / O").accessibilityLabel("对焦点放大").accessibilityValue(m.focusTracking ? "切图保持" : "未开启")
                        Button { m.fitCurrent() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.help("适应窗口，退出对焦点保持 · 、").accessibilityLabel("缩小至适应窗口")
                        Button { m.showsFocusBox.toggle() } label: { Image(systemName: "scope") }
                            .buttonStyle(ViewerToolStyle(active: m.showsFocusBox))
                            .accessibilityLabel("显示绿色对焦框").accessibilityValue(m.showsFocusBox ? "已开启" : "已关闭")
                            .help("显示或隐藏相机记录的对焦框 · F")
                        Divider().frame(height: 16).padding(.horizontal,4)
                        Button { m.toggleFilmstrip() } label: { Image(systemName: "rectangle.split.3x1") }.buttonStyle(ViewerToolStyle(active: m.filmstripVisible)).help("显示或隐藏缩略图预览条 · T").accessibilityLabel("缩略图预览条").accessibilityValue(m.filmstripVisible ? "已开启" : "已关闭")
                        Button(action: m.toggleBursts) {
                            if m.scanningBursts { ProgressView().controlSize(.mini) }
                            else { Image(systemName: m.burstsCollapsed ? "square.stack.fill" : "square.stack") }
                        }.buttonStyle(ViewerToolStyle(active: m.burstsCollapsed))
                            .disabled(m.root.isEmpty || m.working || m.scanningBursts || m.currentProjectOffline)
                            .accessibilityLabel(m.burstsCollapsed ? "展开全部连拍" : "折叠全部连拍")
                            .help(m.burstsCollapsed ? "展开全部连拍 · B" : "折叠全部连拍 · B。文件操作只作用于当前照片。")
                        Button { m.exif.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(ViewerToolStyle(active: m.exif)).help("照片信息 · I").accessibilityLabel("照片信息")
                        Button { m.immersive.toggle() } label: { Image(systemName: m.immersive ? "sidebar.left" : "arrow.up.left.and.arrow.down.right") }.buttonStyle(ViewerToolStyle(active: m.immersive)).help("沉浸模式 · Tab")
                        Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right.square") }.help("全屏 · Control Command F")
                        Button { Task { await m.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(m.busy).help("刷新配对")
                    }.buttonStyle(ViewerToolStyle()).padding(3).glassEffect(.regular.interactive(),in: RoundedRectangle(cornerRadius: 9))
                }
            }.tint(Color.primary)
        }.padding(.horizontal,12).padding(.vertical,10)
    }
    func poolTab(_ title: String, count: Int, pool: Bool) -> some View {
        let active = m.showPool == pool
        let hue: FilterPalette = pool ? .orange : .green
        return Button { m.switchPool(pool) } label: {
            HStack(spacing: 5) {
                Circle().fill(active ? hue.color : Color.secondary.opacity(0.35)).frame(width: 5,height: 5)
                Text(title).fixedSize()
                Text(count.formatted(.number.notation(.compactName))).font(.system(size: 10, weight: .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: 25, alignment: .trailing)
            }.font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? hue.ink(dark: colorScheme == .dark) : Color.secondary)
                .frame(width: 86, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(hue.color.opacity(active ? 0.16 : 0)))
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: active)
        }.buttonStyle(.plain).accessibilityLabel("\(title) \(count)").accessibilityValue(active ? "当前照片池" : "")
    }
    var records: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            Text("操作记录").font(.system(size: 30, weight: .medium))
            if !m.poolBatches.isEmpty {
                HStack { Label("待删池 · \(m.poolBatches.count) 组", systemImage: "tray.full").foregroundStyle(FilterPalette.orange.ink(dark: colorScheme == .dark)); Spacer(); Button("复核待删池") { m.page = 1; m.switchPool(true) }.buttonStyle(.glass); Button("全部恢复正式池") { m.returnFromPool(all: true) }.buttonStyle(.glass).disabled(m.working) }.padding(20).background(FilterPalette.orange.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
            Text("\(m.paired) 对已验证 · \(m.orphanRaw) 个独立 RAW · \(m.ambiguous) 个配对歧义").foregroundStyle(.secondary)
            HStack { Button("刷新记录") { Task { await m.scan() } }.buttonStyle(.glass); Button("撤销上次整理") { confirmUndo = true }.buttonStyle(.glass).disabled(m.history.isEmpty); Button("撤回最近删除") { m.restore() }.buttonStyle(.glass).disabled(m.trash.isEmpty) }.disabled(m.working || m.root.isEmpty)
            if m.history.isEmpty { Text("正式整理后，操作记录会保存在素材目录中。\n也可以直接打开已分离的 JPEG / RAW 父目录来验证配对。").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 30) }
            ForEach(m.history) { record in HStack { Image(systemName: "checkmark.circle").foregroundStyle(accent); VStack(alignment: .leading, spacing: 7) { Text(record.timestamp.replacingOccurrences(of: "T", with: "  ")).font(.system(size: 14, weight: .medium)); Text("\(record.mode) · \(record.moved) 个文件").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Button("查看日志") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)]) }.buttonStyle(.glass) }.padding(20).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)) }
        }.padding(36).frame(maxWidth: .infinity, alignment: .leading) }
    }
    func installKeys() {
        guard m.keyMonitor == nil else { return }
        m.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow != nil, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
                  NSApp.keyWindow?.sheetParent == nil, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            return m.handleKey(event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) ? nil : event
        }
    }
}

struct FilterApp: App {
    @StateObject var model = Model()
    @State private var didApplyLaunchPhoto = false
    var body: some Scene {
        WindowGroup("ZFilter") { ContentView().environmentObject(model).onAppear {
            NSApp.applicationIconImage = AppArtwork.icon; NSApp.dockTile.display()
            model.startProjectMonitoring()
            if let i = CommandLine.arguments.firstIndex(of: "--project"), CommandLine.arguments.indices.contains(i+1), model.root.isEmpty { model.open(CommandLine.arguments[i+1]) }
        }.onChange(of: model.busy) { _, busy in
            guard !busy, !didApplyLaunchPhoto else { return }; didApplyLaunchPhoto = true
            if let i = CommandLine.arguments.firstIndex(of: "--photo"), CommandLine.arguments.indices.contains(i+1) {
                model.page = 1; model.exif = CommandLine.arguments.contains("--info")
                if let index = model.photos.firstIndex(where: { model.displayPath($0) == CommandLine.arguments[i+1] }) { model.index = index }
                model.prefetch()
            }
        }.onOpenURL { url in if url.isFileURL { model.open(url.path) } } }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("打开素材文件夹…", action: model.choose).keyboardShortcut("o").disabled(model.working) }
            CommandGroup(replacing: .undoRedo) { Button("撤回删除", action: model.restore).keyboardShortcut("z").disabled(model.trash.isEmpty || model.busy) }
            CommandMenu("浏览") {
                Button("对焦点放大至 100%（切图保持）") { model.focusCurrent() }.keyboardShortcut("0", modifiers: [])
                Button("适应窗口") { model.fitCurrent() }.keyboardShortcut(",", modifiers: [])
                Button(model.filmstripVisible ? "隐藏缩略图预览条" : "显示缩略图预览条") { model.toggleFilmstrip() }.keyboardShortcut("t", modifiers: [])
                Button(model.burstsCollapsed ? "展开全部连拍" : "折叠全部连拍", action: model.toggleBursts).keyboardShortcut("b", modifiers: [])
                Button(model.showsFocusBox ? "隐藏绿色对焦框" : "显示绿色对焦框") { model.showsFocusBox.toggle() }.keyboardShortcut("f", modifiers: [])
 Button("上一张") { model.step(-1) }.keyboardShortcut(.leftArrow, modifiers: []); Button("下一张") { model.step(1) }.keyboardShortcut(.rightArrow, modifiers: []); Button("照片信息") { model.exif.toggle() }.keyboardShortcut("i", modifiers: []); Button("沉浸模式") { model.immersive.toggle() }.keyboardShortcut(.tab, modifiers: []); Button("刷新配对") { Task { await model.scan() } }.keyboardShortcut("r") }
        }
    }
}

@main struct FilterEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--render-previews") { do { try await runVisualChecks() } catch { fputs("\(error)\n", stderr); exit(1) }; return }
        if CommandLine.arguments.contains("--display-benchmark") { await runDisplayBenchmark(); return }
        if CommandLine.arguments.contains("--self-test") { await runNativeTests(); return }
        FilterApp.main()
    }
}
