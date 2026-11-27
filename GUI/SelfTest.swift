import Foundation
import AppKit
import QuartzCore
import Darwin
import SwiftUI
import Combine
import ImageIO

@MainActor func runNativeTests() async {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("Filter-native-" + UUID().uuidString)
    do {
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let source = CommandLine.arguments.last.flatMap { $0 == "--self-test" ? nil : $0 } ?? "test"
        let sourceTree = URL(fileURLWithPath: source)
        let originals = temp.appendingPathComponent("input")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        func copyInput() throws {
            let enumerator = fm.enumerator(at: sourceTree, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!
            for case let file as URL in enumerator where ["jpg", "jpeg", "nef"].contains(file.pathExtension.lowercased()) {
                try fm.copyItem(at: file, to: originals.appendingPathComponent(file.lastPathComponent))
            }
        }
        try copyInput()
        func canonical(_ url: URL) -> String {
            guard let path = realpath(url.path, nil) else { return url.path }
            defer { free(path) }; return String(cString: path)
        }
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw FileActions.failure("FAIL: " + message) } }
        for selection in ["JPEG", "RAW", "BOTH"] {
            let root = temp.appendingPathComponent(selection)
            let jpgDir = root.appendingPathComponent("Jpg" + selection).appendingPathComponent("20261101Jpg" + selection)
            let rawDir = root.appendingPathComponent("Raw" + selection).appendingPathComponent("20261101Raw" + selection)
            try fm.createDirectory(at: jpgDir, withIntermediateDirectories: true); try fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
            let j = jpgDir.appendingPathComponent("DSC_0920.JPG"), r = rawDir.appendingPathComponent("DSC_0920.NEF")
            try fm.copyItem(at: originals.appendingPathComponent(j.lastPathComponent), to: j)
            try fm.copyItem(at: originals.appendingPathComponent(r.lastPathComponent), to: r)
            let jpegData = try Data(contentsOf: j), rawData = try Data(contentsOf: r)
            let photo = Photo(jpeg: j.path, raw: r.path, status: "已配对", source: "test")
            let paths = selection == "JPEG" ? [j.path] : selection == "RAW" ? [r.path] : [j.path, r.path]
            let batch = try await FileActions.perform { try FileActions.stage(photo, paths: paths, root: root.path) }
            try check(batch.entries.count == paths.count, "selected files")
            for entry in batch.entries {
                try check(!fm.fileExists(atPath: entry.original) && fm.fileExists(atPath: entry.trash), "moved, never copied")
                try check(entry.trash.contains(selection == "RAW" || entry.original == r.path ? "/DRaw" : "/DJpg"), "parallel D directory")
                try check(entry.trash.contains("20261101"), "travel structure")
            }
            if selection == "JPEG" { try check(fm.fileExists(atPath: r.path), "JPEG-only preserves RAW") }
            if selection == "RAW" { try check(fm.fileExists(atPath: j.path), "RAW-only preserves JPEG") }
            let reloaded = try FileActions.read([PoolBatch].self, FileActions.poolURL(root.path), default: [])
            try check(reloaded.count == 1 && reloaded[0].id == batch.id, "durable journal")
            // Real bridge scan of the native journal tests cross-language compatibility.
            let library: [String: Any] = try await FileActions.perform {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [Bundle.main.resourceURL!.appendingPathComponent("filter_bridge.py").path]
                let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
                try process.run(); input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["action": "scan", "root": root.path])); try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            try check((library["photos"] as? [Any])?.count == (selection == "RAW" ? 1 : 0), "W preserves untouched active JPEG")
            try check((library["poolPhotos"] as? [Any])?.count == (selection == "RAW" ? 0 : 1), "JPEG pool contains only physically staged JPEG")
            try check((library["rawPhotos"] as? [Any])?.count == (selection == "JPEG" ? 1 : 0), "W preserves untouched active RAW")
            try check((library["poolRawPhotos"] as? [Any])?.count == (selection == "JPEG" ? 0 : 1), "RAW pool contains only physically staged RAW")
            let temporarilyMissing = batch.entries[0]
            let held = temp.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(atPath: temporarilyMissing.trash, toPath: held.path)
            var missingBlocked = false
            do { try FileActions.restorePool([batch.id], root: root.path) } catch { missingBlocked = true }
            let stillRecorded = try FileActions.read([PoolBatch].self, FileActions.poolURL(root.path), default: [])
            try check(missingBlocked && stillRecorded.count == 1, "missing files retain recovery mapping")
            try fm.moveItem(atPath: held.path, toPath: temporarilyMissing.trash)
            // Restore refuses to overwrite and leaves durable recovery information intact.
            let first = batch.entries[0]
            try Data("collision".utf8).write(to: URL(fileURLWithPath: first.original))
            var blocked = false
            do { try FileActions.restorePool([batch.id], root: root.path) } catch { blocked = true }
            try check(blocked && fm.fileExists(atPath: first.trash), "restore collision protection")
            try fm.removeItem(atPath: first.original)
            try await FileActions.perform { try FileActions.restorePool([batch.id], root: root.path) }
            let restoredJ = try Data(contentsOf: j), restoredR = try Data(contentsOf: r)
            try check(restoredJ == jpegData && restoredR == rawData, "lossless round trip")
            // Existing files in D-pool never get overwritten.
            let target = try FileActions.shadowDestination(j.path, root: root.path, isRaw: false)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("keep".utf8).write(to: target)
            let collision = try FileActions.stage(photo, paths: [j.path], root: root.path)
            let untouched = try Data(contentsOf: target)
            try check(collision.entries[0].trash != target.path && untouched == Data("keep".utf8), "D-pool collision")
            try FileActions.restorePool([collision.id], root: root.path)
            print("PASS native pool: \(selection), parallel/travel paths, bridge active/pool, persistent recovery, collisions, original bytes")
        }
        let mixed = temp.appendingPathComponent("DCIM"); try fm.createDirectory(at: mixed, withIntermediateDirectories: true)
        let mixedJ = mixed.appendingPathComponent("X.JPG"); try Data("mixed".utf8).write(to: mixedJ)
        let batch = try FileActions.stage(Photo(jpeg: mixedJ.path, raw: nil, status: "仅 JPEG", source: ""), paths: [mixedJ.path], root: mixed.path)
        try check(batch.entries[0].trash.contains("/DJpgDCIM/"), "unorganized folder fallback")
        try FileActions.restorePool([batch.id], root: mixed.path)
        print("PASS mixed/unorganized folder pool recovery")
        // Exercise the production model and its exact WASD routes without desktop automation.
        let suite = "Filter-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let flow = temp.appendingPathComponent("项目流程")
        try fm.copyItem(at: originals, to: flow)
        let model = Model(preferences: preferences, journal: temp.appendingPathComponent("trash.json"))
        func settle(_ model: Model) async throws {
            for _ in 0..<300 {
                await Task.yield()
                if !model.working { if let error = model.error { throw FileActions.failure(error) }; return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw FileActions.failure("model operation timeout")
        }
        model.open(flow.path)
        try check(model.busy && model.projectReadState == .loading && model.counts.isEmpty, "opening project publishes loading state immediately")
        try await settle(model)
        try check(model.counts["jpg"] == 7 && model.counts["raw"] == 7 && model.formats["NEF"] == 7, "automatic inventory")
        try check(model.preview["will_rule1_jpg"] == 7, "ready to confirm without manual precheck")
        model.travel = true
        await model.run()
        try check(model.organized && model.history.count == 1 && model.photos.count == 7, "organized project summary")
        let reopened = Model(preferences: preferences, journal: temp.appendingPathComponent("trash.json"))
        try check(reopened.projects.first?.organized == true, "persistent project history")
        reopened.page = 1; reopened.open(flow.path)
        try check(reopened.projectReadState == .loading && reopened.current == nil, "viewer opens in loading state before pairing results exist")
        try await settle(reopened)
        try check(reopened.page == 1 && reopened.projectReadState == .ready && reopened.current != nil, "opening project preserves browsing context and shows results")
        let unavailable = temp.appendingPathComponent("initially-unavailable")
        reopened.open(unavailable.path)
        for _ in 0..<300 where reopened.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(!reopened.busy && reopened.projectReadState == .failed && reopened.error != nil, "failed folder read is distinct from an empty pairing result")
        try fm.createDirectory(at: unavailable, withIntermediateDirectories: false)
        await reopened.scan()
        try check(reopened.projectReadState == .ready && reopened.current == nil && reopened.error == nil, "retry of a readable empty folder yields a confirmed empty result")
        model.page = 1
        try check(model.handleKey(2) && model.index == 1, "D next")
        try check(model.handleKey(0) && model.index == 0, "A previous")
        let first = model.current!
        let began = CACurrentMediaTime(); model.handleKey(13)
        let rejectTime = (CACurrentMediaTime()-began)*1000
        try check(model.current?.id != first.id && model.activePhotos.count == 6, "W switches immediately before file IO")
        try await settle(model)
        try check(model.poolPhotos.count == 1 && model.poolBatches.count == 1, "W shadow pool")
        model.switchPool(true); model.returnFromPool(); try await settle(model)
        try check(model.activePhotos.count == 7 && model.poolPhotos.isEmpty, "restore current from pool")
        model.switchPool(false); model.deleteMode = "仅 RAW"
        let rawOnly = model.current!
        model.handleKey(13); try await settle(model); await model.scan()
        try check(model.activePhotos.count == 7 && model.activeRawPhotos.count == 6 && model.poolRawPhotos.count == 1 && model.poolPhotos.isEmpty, "RAW-only W preserves JPEG view and stages only RAW after rescan")
        try check(fm.fileExists(atPath: rawOnly.jpeg) && !fm.fileExists(atPath: rawOnly.raw!), "RAW-only W preserves physical JPEG")
        model.returnFromPool(all: true); try await settle(model)
        // Rapid culling queues mutations serially but never holds the next photo behind disk IO.
        model.deleteMode = "JPEG + RAW"
        model.index = 0
        model.handleKey(13); model.handleKey(13); model.handleKey(13)
        try check(model.activePhotos.count == 4, "rapid W immediate departure")
        try await settle(model)
        try check(model.poolBatches.count == 3 && model.poolPhotos.count == 3, "rapid W durable batches")
        let restarted = Model(preferences: preferences, journal: temp.appendingPathComponent("trash.json"))
        restarted.open(flow.path); try await settle(restarted)
        try check(restarted.poolPhotos.count == 3 && restarted.activePhotos.count == 4, "pool survives app restart")
        model.returnFromPool(all: true); try await settle(model)
        model.deleteMode = "仅 RAW"
        let rejected = model.current!
        model.handleKey(1)
        try check(model.current?.id != rejected.id, "S advances even RAW-only")
        try await settle(model)
        try check(fm.fileExists(atPath: rejected.jpeg) && !fm.fileExists(atPath: rejected.raw!), "S selected RAW is trashed")
        model.handleKey(6, modifiers: .command); try await settle(model)
        try check(fm.fileExists(atPath: rejected.raw!), "Cmd-Z restores trash")
        model.deleteMode = "JPEG + RAW"; let both = model.current!
        model.handleKey(1); try await settle(model)
        try check(!fm.fileExists(atPath: both.jpeg) && !fm.fileExists(atPath: both.raw!), "S both")
        model.restore(); try await settle(model)
        model.toggleSidebar()
        try check(Model(preferences: preferences).collapsed == model.collapsed, "icon sidebar preference")
        try check(model.activePhotos.count == 7 && model.poolBatches.isEmpty && model.trash.isEmpty, "all restored")
        let activePair = model.current!
        model.handleKey(13); try await settle(model)
        let originalPoolPhoto = model.poolPhotos.first!
        try check(model.poolRemoval == nil && model.poolDirectories.count == 2, "whole-pool action belongs to the pool and sees newly staged folders")
        let emptyPool = flow.appendingPathComponent("卡片/DRaw空目录")
        let unrelated = flow.appendingPathComponent("Drawings")
        try fm.createDirectory(at: emptyPool, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let nestedPool = flow.appendingPathComponent("卡片/DRaw空目录/DJpg内层")
        try fm.createDirectory(at: nestedPool, withIntermediateDirectories: false)
        let sidecar = nestedPool.appendingPathComponent("保留.xmp")
        try Data("sidecar".utf8).write(to: sidecar)
        try fm.createSymbolicLink(at: flow.appendingPathComponent("DJpg外部链接"), withDestinationURL: unrelated)
        model.switchPool(true); model.deleteMode = "仅 JPEG"; await model.scan()
        let plan = model.poolRemoval!
        try check(plan.directories.count == 3 && plan.directories.contains(canonical(emptyPool)), "inventory includes unpaired and sidecar-only pool roots once, and excludes symbolic links")
        let invalid = PoolRemoval(root: plan.root, directories: plan.directories + [canonical(unrelated)])
        await model.removePool(invalid)
        try check(model.error != nil && plan.directories.allSatisfy { fm.fileExists(atPath: $0) }, "changed confirmation is rejected before moving any folder")
        model.error = nil
        var blockedFormal = false
        do { _ = try FileActions.trash(invalid.directories, journal: model.journal, poolRoot: plan.root) }
        catch { blockedFormal = true }
        try check(blockedFormal && plan.directories.allSatisfy { fm.fileExists(atPath: $0) }, "filesystem validation rejects formal paths before moving any folder")
        await model.removePool(plan)
        try check(model.error == nil && model.poolDirectories.isEmpty && model.poolBatches.isEmpty && model.showPool,
                  "successful bulk delete refreshes this pool with no stale batches (\(model.error ?? "no error"))")
        try check(plan.directories.allSatisfy { !fm.fileExists(atPath: $0) } && fm.fileExists(atPath: unrelated.path), "all confirmed directories leave project; unrelated folders remain")
        try check(model.trash.count == 1 && model.trash.last?.count == 3, "bulk delete records a single undo group")
        model.restore(); try await settle(model)
        try check(model.poolDirectories == plan.directories && model.poolBatches.count == 1 && model.trash.isEmpty, "Cmd-Z restores directories and recorded pair together")
        let restoredSidecar = try Data(contentsOf: sidecar)
        try check(restoredSidecar == Data("sidecar".utf8) && fm.fileExists(atPath: originalPoolPhoto.jpeg), "undo restores sidecars and staged JPEG bytes")
        model.returnFromPool(all: true); try await settle(model)
        try check(fm.fileExists(atPath: activePair.jpeg) && fm.fileExists(atPath: activePair.raw!), "restored pool still resolves the original formal pair")
        print("PASS macOS whole-pool confirmation snapshot, all scopes, nested directories, symlink exclusion, and bulk Cmd-Z")
        let unorganized = temp.appendingPathComponent("原始素材")
        for branch in ["甲/子目录", "乙/子目录"] {
            let folder = unorganized.appendingPathComponent(branch)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["DSC_0920.JPG", "DSC_0920.NEF"] {
                try fm.copyItem(at: originals.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
        }
        try fm.createDirectory(at: unorganized.appendingPathComponent("乙/空目录"), withIntermediateDirectories: false)
        model.open(unorganized.path); try await settle(model)
        let selectedBranch = model.root + "/甲"
        try check(model.activeFolders.contains(model.root + "/乙/空目录"), "empty nested folders are browsable")
        model.mode = "shadow"; await model.run()
        guard let mirror = model.shadowPool else { throw FileActions.failure(model.error ?? "Missing shadow configuration") }
        try check(model.page == 1 && model.activePhotos.count == 2 && model.poolPhotos.isEmpty && model.history.isEmpty,
                  "shadow setup enters culling and leaves formal photos and history intact")
        try check(fm.fileExists(atPath: mirror.path + "/乙/空目录") && model.poolFolders.contains(mirror.path + "/甲/子目录"),
                  "empty directory tree is mirrored in the sibling")
        model.deleteMode = "JPEG + RAW"
        model.selectFolder(selectedBranch)
        try check(model.photos.count == 1 && model.currentPath?.hasPrefix(selectedBranch + "/") == true,
                  "recursive folder scope distinguishes same names")
        let toStage = model.current!
        model.handleKey(13); try await settle(model)
        let relative = String(toStage.jpeg.dropFirst(model.root.count))
        try check(fm.fileExists(atPath: mirror.path + relative) && fm.fileExists(atPath: model.root + "/乙/子目录/DSC_0920.JPG"),
                  "W moves the intended pair to the corresponding nested shadow paths")
        model.switchPool(true)
        model.selectFolder(mirror.path + "/甲/子目录")
        try check(model.photos.count == 1 && model.currentPath == mirror.path + relative, "scoped shadow pool preserves pairing")
        model.returnFromPool(); try await settle(model)
        try check(fm.fileExists(atPath: toStage.jpeg) && fm.fileExists(atPath: toStage.raw!) && model.photos.isEmpty,
                  "W restores original paths and retains the browsed empty directory")
        model.switchPool(false)
        try check(model.selectedFolders[false] == selectedBranch && model.photos.count == 1, "formal and pending folder scopes are independent")
        model.handleKey(13); try await settle(model)
        model.switchPool(true)
        let mirrorPlan = model.poolRemoval!
        await model.removePool(mirrorPlan)
        try check(!fm.fileExists(atPath: mirror.path) && model.error == nil && model.activePhotos.count == 1, "bulk recycle accepts only the owned sibling")
        model.restore(); try await settle(model)
        try check(fm.fileExists(atPath: mirror.path + relative) && model.poolPhotos.count == 1, "Cmd-Z restores the shadow pool")
        print("PASS macOS shadow creation, duplicate filenames, directory browsing, W restore and whole-pool undo")
        print(String(format: "PASS project/WASD: loading, auto inventory, organize, persistent projects, context, A/D, W/S immediate advance %.3f ms, pool review/restore, RAW-only, Cmd-Z, sidebar", rejectTime))
        let selectedParent = temp.appendingPathComponent("scope-parent")
        let selectedChild = selectedParent.appendingPathComponent("selected-child")
        try fm.createDirectory(at: selectedParent, withIntermediateDirectories: true)
        try fm.copyItem(at: originals, to: selectedChild)
        try fm.createDirectory(at: selectedParent.appendingPathComponent(".nikonfilter_logs"), withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: selectedParent.appendingPathComponent("not-selected.JPG"))
        let scoped = Model(preferences: preferences, journal: temp.appendingPathComponent("scope-trash.json"))
        scoped.open(selectedChild.path); try await settle(scoped)
        try check(scoped.root == canonical(selectedChild) && scoped.counts["jpg"] == 7 && scoped.pendingFiles == 14 && !scoped.organized, "production model honors selected child with ancestor logs")
        let savedChildren = try fm.subpathsOfDirectory(atPath: selectedChild.path).sorted()
        scoped.removeProject(canonical(flow))
        try check(scoped.root == canonical(selectedChild) && fm.fileExists(atPath: flow.path), "remove inactive project preserves current selection and files")
        scoped.removeProject(scoped.root)
        try check(scoped.root.isEmpty && scoped.counts.isEmpty && scoped.photos.isEmpty && scoped.history.isEmpty, "remove active project resets view")
        let savedAfterRemoval = Model(preferences: preferences)
        try check(!savedAfterRemoval.projects.contains { $0.root == canonical(selectedChild) || $0.root == canonical(flow) }, "project removal persists without legacy resurrection")
        let childrenAfterRemoval = try fm.subpathsOfDirectory(atPath: selectedChild.path).sorted()
        try check(savedChildren == childrenAfterRemoval && fm.fileExists(atPath: flow.path), "project removal never touches media or logs")
        scoped.open(selectedChild.path); try await settle(scoped)
        try check(scoped.photos.count == 7 && scoped.pendingFiles == 14, "removed folder can be explicitly reopened")
        print("PASS selected-child root/stats and project removal: current/inactive, persistent, files untouched, reopen")
        let mixedFlow = temp.appendingPathComponent("先选后整理")
        try fm.copyItem(at: originals, to: mixedFlow)
        let beforeSort = Model(preferences: preferences, journal: temp.appendingPathComponent("trash2.json"))
        beforeSort.open(mixedFlow.path); try await settle(beforeSort)
        beforeSort.page = 1; beforeSort.deleteMode = "仅 RAW"; beforeSort.handleKey(13); try await settle(beforeSort)
        await beforeSort.run()
        try check(beforeSort.activePhotos.count == 7 && beforeSort.activeRawPhotos.count == 6 && beforeSort.poolRawPhotos.count == 1, "organize never reintroduces staged RAW; untouched JPEG remains visible")
        beforeSort.switchPool(true); beforeSort.returnFromPool(); try await settle(beforeSort)
        try check(beforeSort.activePhotos.count == 7 && beforeSort.poolPhotos.isEmpty && beforeSort.paired == 7, "restore after organizing remaining files")
        print("PASS organize while pool exists, relocated JPEG mapping, pool restoration")
        let path = originals.appendingPathComponent("DSC_0920.JPG").path
        let benchmarkStore = ImageStore()
        let start = CACurrentMediaTime()
        let frame: ImageFrame? = await withCheckedContinuation { continuation in benchmarkStore.load(path) { continuation.resume(returning: $0) } }
        try check(frame?.image.width == 6192, "full-resolution decode")
        let decode = (CACurrentMediaTime()-start)*1000
        let cachedStart = CACurrentMediaTime()
        let cached: ImageFrame? = await withCheckedContinuation { continuation in benchmarkStore.load(path) { continuation.resume(returning: $0) } }
        try check(frame === cached, "warm cache reuses decoded image")
        let cacheTime = (CACurrentMediaTime()-cachedStart)*1000
        let scroll = PhotoScroll(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scroll.picture.layer?.contents = frame?.image; scroll.pixelSize = NSSize(width: 6192, height: 4128); scroll.picture.frame = NSRect(origin: .zero, size: scroll.pixelSize)
        scroll.fitImage(); scroll.toggleZoom(at: NSPoint(x: 3000, y: 2000))
        var durations: [Double] = []
        for i in 0..<600 {
            let began = CACurrentMediaTime()
            var rect = scroll.contentView.bounds; rect.origin.x = CGFloat(i%300)*5; rect.origin.y = CGFloat(i%200)*5
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin); scroll.reflectScrolledClipView(scroll.contentView)
            durations.append((CACurrentMediaTime()-began)*1000)
        }
        durations.sort()
        print(String(format: "PERF 6192×4128: decode %.2f ms; warm cache %.3f ms; 600 layer pans CPU median %.3f ms, p95 %.3f ms, max %.3f ms", decode, cacheTime, durations[300], durations[570], durations.last!))
        try await runEnhancementTests(originals, temp: temp)
        print("ALL NATIVE TESTS PASS")
    } catch { fputs("\(error)\n", stderr); exit(1) }
}

@MainActor final class DisplayProbe: NSObject {
    let scroll: PhotoScroll
    var times: [Double] = [], costs: [Double] = []
    init(_ scroll: PhotoScroll) { self.scroll = scroll }
    @objc func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(); times.append(now)
        var bounds = scroll.contentView.bounds
        bounds.origin = NSPoint(x: 1500 + sin(now*2)*800, y: 1000 + cos(now*2)*600)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        costs.append((CACurrentMediaTime()-now)*1000)
    }
    func run() {
        let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        let end = Date().addingTimeInterval(3)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        link.invalidate()
        let stable = Array(times.dropFirst(10))
        let intervals = zip(stable.dropFirst(), stable).map { ($0-$1)*1000 }.sorted()
        guard stable.count > 30 else { print("DISPLAY BENCHMARK FAILED: insufficient display callbacks"); exit(1) }
        let hz = Double(stable.count-1)/(stable.last!-stable.first!)
        costs.sort()
        print(String(format: "DISPLAY 1:1, 6192×4128, live scroll (no border): %.1f Hz; callback intervals p95 %.2f ms; pan CPU p95 %.3f ms; %d callbacks", hz, intervals[Int(Double(intervals.count)*0.95)], costs[Int(Double(costs.count)*0.95)], times.count))
    }
}
@MainActor func runDisplayBenchmark() async {
    let application = NSApplication.shared; application.setActivationPolicy(.accessory)
    let path = CommandLine.arguments.last!
    guard let frame: ImageFrame = await withCheckedContinuation({ continuation in ImageStore.shared.load(path) { continuation.resume(returning: $0) } }) else { print("Missing benchmark image"); exit(1) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Filter · 1:1 显示性能测试"
    let scroll = PhotoScroll(frame: NSRect(x: 0, y: 0, width: 1000, height: 700)); scroll.fit = false
    scroll.picture.layer?.contents = frame.image; scroll.pixelSize = NSSize(width: frame.image.width, height: frame.image.height); scroll.picture.frame = NSRect(origin: .zero, size: scroll.pixelSize)
    window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil)
    scroll.magnification = 1/(window.backingScaleFactor)
    DisplayProbe(scroll).run()
    window.orderOut(nil)
}

@MainActor func runEnhancementTests(_ originals: URL, temp: URL) async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw FileActions.failure("FAIL: " + message) } }
    let jpeg = originals.appendingPathComponent("DSC_0926.JPG").path
    let raw = originals.appendingPathComponent("DSC_0926.NEF").path
    try runMetadataTests(jpeg,temp: temp)
    try runHistogramTests(jpeg)
    try await runProjectOrderingTests(temp)
    guard let point = FocusMetadata.read(jpeg), let rawPoint = FocusMetadata.read(raw) else { throw FileActions.failure("real Nikon focus metadata missing") }
    try require(point.version == "0400" && abs(point.x-3813.0/8256) < 0.000001 && abs(point.y-1979.0/5504) < 0.000001, "real Nikon AF coordinates match reference header")
    try require(abs(point.x-rawPoint.x) < 0.000001 && abs(point.y-rawPoint.y) < 0.000001, "JPEG/NEF focus coordinates agree")
    let (recordedJPEG, jpegPreset) = FocusMetadata.recorded(jpeg)
    let (recordedRAW, rawPreset) = FocusMetadata.recorded(raw)
    try require(abs((recordedJPEG.distance ?? 0)-1.26) < 0.01 && recordedJPEG.distance == recordedRAW.distance, "real Nikon JPEG and NEF focus distance match ExifTool reference")
    try require(recordedJPEG.mode == "AF-C" && recordedJPEG.areaMode == "自动区域" && recordedJPEG.inFocus == true, "real Nikon details record AF-C, automatic area, and confirmed focus")
    try require(jpegPreset == rawPreset && jpegPreset?.name == "ArmitageProvia100F" && jpegPreset?.base == "FLEXIBLE COLOR", "real Nikon JPEG and NEF have the same recorded color preset and base")
    try require(NikonPictureControl.decode(Array("0310abcdef".utf8)[...]) == nil, "truncated Nikon Picture Control is ignored")
    let expected: [(Double,Double)] = [(0.3,0.25),(0.7,0.25),(0.7,0.75),(0.3,0.75),(0.25,0.3),(0.75,0.3),(0.75,0.7),(0.25,0.7)]
    for little in [true,false] {
        for version in ["0300","0301","0400","0401","0402"] {
            var data = [UInt8](repeating:0,count:80); data.replaceSubrange(0..<4,with:version.utf8); data[7]=1
            let offset = version.hasPrefix("04") ? 62 : 42
            for (i,value) in [1000,800,300,200,50,30].enumerated() {
                let pos=offset+i*2
                data[pos] = UInt8(little ? value & 255 : value >> 8); data[pos+1] = UInt8(little ? value >> 8 : value & 255)
            }
            for orientation in 1...8 {
                guard let decoded=FocusMetadata.decodeAF(data,little:little,orientation:orientation) else { throw FileActions.failure("AF layout decode") }
                try require(abs(decoded.x-expected[orientation-1].0)<0.00001 && abs(decoded.y-expected[orientation-1].1)<0.00001, "all EXIF rotations/mirrors")
                try require(decoded.areaSize == (orientation >= 5 ? CGSize(width: 30.0/800,height: 50.0/1000) : CGSize(width: 50.0/1000,height: 30.0/800)), "recorded AF rectangle rotates with image")
            }
            data[7]=0; try require(FocusMetadata.decodeAF(data,little:little,orientation:1)==nil,"unavailable coordinates are never guessed")
        }
    }
    for data in [Data(),Data([0xff,0xd8,0xff,0xe1,0xff,0xff]),Data(repeating:255,count:200)] { try require(FocusMetadata.parse(data)==nil,"malformed metadata is bounded") }
    let scroll=PhotoScroll(frame:NSRect(x:0,y:0,width:1000,height:700)); scroll.load(jpeg)
    for _ in 0..<200 { if !scroll.loading { break }; try await Task.sleep(nanoseconds:10_000_000) }
    try require(!scroll.loading && scroll.pixelSize.width==6192,"real preview ready")
    let suite="Filter-enhancement-"+UUID().uuidString
    let preferences=UserDefaults(suiteName:suite)!
    let model=Model(preferences:preferences,journal:temp.appendingPathComponent("enhance-trash.json"))
    model.activePhotos=[Photo(jpeg:jpeg,raw:raw,status:"已配对",source:"test")]; model.page=1
    try require(model.handleKey(29),"0 is routed to focus zoom")
    for _ in 0..<100 { if !scroll.fit { break }; try await Task.sleep(nanoseconds:10_000_000) }
    let focusX=point.x*scroll.pixelSize.width, focusY=(1-point.y)*scroll.pixelSize.height
    try require(model.handleKey(3) && model.showsFocusBox && Model(preferences: preferences).showsFocusBox, "F toggles focus frame and persists the preference")
    scroll.showsFocusBox = model.showsFocusBox; scroll.updateFocusBox()
    let box = scroll.picture.focusBox.path?.boundingBox
    try require(abs((box?.midX ?? 0)-focusX)<0.01 && abs((box?.midY ?? 0)-focusY)<0.01 && abs((box?.width ?? 0)-147)<1, "real Nikon display rect uses correct position and area width at 100%")
    try require(abs(scroll.magnification-0.5)<0.00001 && abs(scroll.contentView.bounds.midX-focusX)<2 && abs(scroll.contentView.bounds.midY-focusY)<2,"0 gives true pixel 100% centered on focus")
    try require(model.handleKey(42,characters:"、") && scroll.fit,"enumeration comma fits image")
    scroll.toggleZoom(at:NSPoint(x:4000,y:2200))
    try require(!scroll.fit && abs(scroll.contentView.bounds.midX-4000)<2,"ordinary click centers at click, not focus")
    model.handleKey(82)
    for _ in 0..<100 { if abs(scroll.contentView.bounds.midX-focusX)<2 { break }; try await Task.sleep(nanoseconds:10_000_000) }
    try require(abs(scroll.contentView.bounds.midX-focusX)<2,"keypad 0 refocuses even when already zoomed")
    model.handleKey(43); try require(scroll.fit,"comma physical key fits")
    var message=""; scroll.focus=nil; scroll.rawPath=nil; scroll.onMessage={message=$0}; scroll.focusZoom()
    for _ in 0..<100 { if !message.isEmpty { break }; try await Task.sleep(nanoseconds:10_000_000) }
    try require(!scroll.fit && scroll.focusTracking && abs(scroll.magnification-0.5)<0.00001 && abs(scroll.contentView.bounds.midX-scroll.pixelSize.width/2)<2 && abs(scroll.contentView.bounds.midY-scroll.pixelSize.height/2)<2 && message.contains("中心"),"missing focus falls back to true 100% at image center without clearing tracking")
    try require(scroll.picture.focusBox.path == nil,"missing coordinates show no green box even when focus zoom centers")
    scroll.rawPath=raw; scroll.focusZoom()
    for _ in 0..<100 { if scroll.focus != nil && abs(scroll.contentView.bounds.midX-focusX)<2 { break }; try await Task.sleep(nanoseconds:10_000_000) }
    try require(!scroll.fit && scroll.focus != nil && abs(scroll.contentView.bounds.midX-focusX)<2,"paired RAW replaces provisional center with real focus coordinates")
    try require(scroll.picture.focusBox.path != nil,"paired RAW focus also draws the overlay")
    scroll.showsFocusBox = false; scroll.updateFocusBox()
    try require(scroll.picture.focusBox.path == nil,"hiding green frame leaves the current image zoom unchanged")
    print("PASS focus playback overlay and detail: Nikon JPEG/NEF 1.26 m, AF-C, real AF region, 8 orientations, F preference, no guessed mark, RAW fallback")
    scroll.applyFocusPoint(FocusPoint(x: 0.1,y: 0.1,aspect: 0.5,version: "test",inFocus: nil))
    try require(abs(scroll.contentView.bounds.midX-scroll.pixelSize.width/2)<2 && scroll.focusTracking,"incompatible AF reference canvas also falls back to center")
    try require(model.handleKey(31),"letter O aliases focus tracking while Command-O remains folder open")
    try await runImageSchedulingTests(jpeg)
    try await runConnectionTests(temp)
    try await runBurstAndScrubberTests(originals, temp: temp)
    try await runViewScopeTests(originals,temp: temp)
    try await runFilmstripTests(originals, temp: temp)
    let storeRoot=temp.appendingPathComponent("storage-refresh")
    try FileManager.default.createDirectory(at:storeRoot,withIntermediateDirectories:true)
    for (name,size) in [("a.JPG",100),("a.NEF",200),("sidecar.xmp",200)] { try Data(repeating:1,count:size).write(to:storeRoot.appendingPathComponent(name)) }
    let stats=Model(preferences:preferences,journal:temp.appendingPathComponent("storage-trash.json"))
    func settleStats() async throws {
        for _ in 0..<300 { await Task.yield(); if !stats.working { if let message=stats.error { throw FileActions.failure(message) }; return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw FileActions.failure("storage operation timeout")
    }
    stats.open(storeRoot.path); try await settleStats()
    try require(stats.sizes["project"]==500 && stats.sizes["jpg"]==100 && stats.sizes["raw"]==200 && stats.mediaCount==2,"native exact byte inventory")
    try Data(repeating:1,count:50).write(to:storeRoot.appendingPathComponent("b.JPG"))
    await stats.refreshProjects(only:stats.root)
    try require(stats.sizes["project"]==550 && stats.mediaCount==3,"refresh active project sizes")
    let otherRoot=temp.appendingPathComponent("other-refresh")
    try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
    try Data(repeating:1,count:65).write(to:otherRoot.appendingPathComponent("video.MOV"))
    stats.open(otherRoot.path); try await settleStats()
    let selectedRoot=stats.root, storedRoot=stats.projects.first { $0.name=="storage-refresh" }!.root
    try Data(repeating:1,count:75).write(to:storeRoot.appendingPathComponent("c.JPG"))
    await stats.refreshProjects(only:storedRoot)
    try require(stats.root==selectedRoot && stats.sizes["project"]==65 && stats.projects.first { $0.root==storedRoot }?.sizes?["project"]==625,"refresh inactive project preserves current context")
    let persisted=Model(preferences:preferences)
    try require(persisted.projects.first { $0.root==storedRoot }?.sizes?["project"]==625,"project bytes persist")
    stats.open(storedRoot); try await settleStats(); stats.page=1; stats.index=stats.photos.firstIndex { $0.raw != nil }!
    let stagedPath = stats.current!.jpeg
    stats.handleKey(13)
    try require(stats.filmstripDepartures.last?.path == stagedPath && stats.filmstripDepartures.last?.kind == .pool && stats.current?.jpeg != stagedPath,"W immediately advances and emits upward thumbnail effect")
    try await settleStats()
    try require(stats.sizes["project"]==625 && stats.sizes["pool"]==300 && stats.sizes["active"]==325,"W preserves total while shifting byte buckets")
    stats.switchPool(true); stats.remove()
    try require(stats.filmstripDepartures.last?.kind == .trash,"S emits thumbnail shatter effect")
    try await settleStats()
    try require(stats.sizes["project"]==325 && stats.sizes["pool"]==0 && stats.mediaCount==2,"S decreases physical project bytes")
    stats.restore(); try await settleStats(); stats.returnFromPool(all:true); try await settleStats()
    try require(stats.sizes["project"]==625 && stats.sizes["pool"]==0 && stats.sizes["jpg"]==225 && stats.sizes["raw"]==200,"undo and pool restore recover sizes")
    let oldProject=Data("{\"root\":\"old\",\"counts\":{\"jpg\":2},\"formats\":{},\"organized\":false,\"updated\":\"old\"}".utf8)
    let legacy=try JSONDecoder().decode(Project.self,from:oldProject)
    try require(legacy.sizes==nil && legacy.count==2,"old project records migrate without losing history")
    if let icon=NSBitmapImageRep(data:try Data(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("AppIcon.png"))) {
        try require(icon.pixelsWide==1024 && icon.pixelsHigh==1024 && icon.colorAt(x:0,y:0)!.alphaComponent==0 && icon.colorAt(x:512,y:512)!.alphaComponent>0.99,"vector icon has standard transparent canvas and intact artwork")
    } else { throw FileActions.failure("icon asset not loaded") }
    let stalled=temp.appendingPathComponent("stalled-scan.py")
    try Data("import json,sys,time\njson.load(sys.stdin)\ntime.sleep(60)\n".utf8).write(to:stalled)
    stats.bridgeOverrideForTests=stalled.path
    let timeoutStart=Date()
    var timeoutCaught=false
    do { _ = try await stats.request("scan", timeout: 0.2) } catch { timeoutCaught=error.localizedDescription.contains("超时") }
    try require(timeoutCaught && Date().timeIntervalSince(timeoutStart)<3,"blocked scan is terminated and reported")
    stats.bridgeOverrideForTests=nil
    print("PASS project bytes: current/inactive refresh, context preserved, persistent/legacy records, W/S/undo/restore accounting, scan timeout; transparent 1024 icon")
    preferences.removePersistentDomain(forName:suite)
    print("PASS focus: real Z8 JPEG+NEF, reference coordinates, 5 layouts × 2 byte orders × 8 orientations, malformed data, 0/keypad0, click-versus-focus, 、 fit, unavailable and RAW fallback")
}

@MainActor func runViewScopeTests(_ originals: URL,temp: URL) async throws {
    func require(_ value: @autoclosure () -> Bool,_ message: String) throws { if !value() { throw FileActions.failure("FAIL: "+message) } }
    let fm = FileManager.default, root = temp.appendingPathComponent("view-scopes")
    try fm.createDirectory(at: root,withIntermediateDirectories: true)
    for name in ["Pair.JPG","Pair.NEF","JOnly.JPG","ROnly.NEF","Amb.JPG","one/Amb.NEF","two/Amb.NEF"] {
        let target = root.appendingPathComponent(name)
        try fm.createDirectory(at: target.deletingLastPathComponent(),withIntermediateDirectories: true)
        try fm.copyItem(at: originals.appendingPathComponent(name.lowercased().hasSuffix("nef") ? "DSC_0926.NEF" : "DSC_0926.JPG"),to: target)
    }
    let suite = "Filter-RAW-"+UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = Model(preferences: preferences,journal: temp.appendingPathComponent("raw-trash.json"))
    func settled() async throws {
        for _ in 0..<1500 { if !model.working { if let error = model.error { throw FileActions.failure(error) }; return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw FileActions.failure("RAW scope operation timeout")
    }
    model.open(root.path); try await settled(); model.page = 1
    try require(model.photos.count == 1 && model.current?.name == "Pair.JPG","pair scope excludes JPEG-only and ambiguous pairings")
    model.deleteMode = "仅 JPEG"; try require(model.photos.count == 3,"JPEG view includes every physical JPEG")
    model.deleteMode = "仅 RAW"; try require(model.photos.count == 4 && Set(model.photos.compactMap(\.raw)).count == 4,"RAW view includes paired, orphan and ambiguous RAW exactly once")
    let orphan = URL(fileURLWithPath: model.root).appendingPathComponent("ROnly.NEF").path
    model.selectPhoto(orphan)
    try require(model.current?.jpeg.isEmpty == true && model.currentPath == orphan,"orphan RAW has its own display identity")
    let start = CACurrentMediaTime()
    let frame: ImageFrame? = await withCheckedContinuation { continuation in ImageStore.shared.load(orphan) { continuation.resume(returning: $0) } }
    guard let frame else { throw FileActions.failure("real unpaired Nikon RAW decode failed") }
    try require(frame.image.width == 8256 && frame.image.height == 5504 && frame.histogram != nil,"RAW displays full sensor resolution and histogram without companion JPEG")
    let rawTime = (CACurrentMediaTime()-start)*1000
    let thumb: CGImage? = await withCheckedContinuation { continuation in ThumbnailStore.shared.load(orphan) { continuation.resume(returning: $0) } }
    try require(thumb != nil && max(thumb!.width,thumb!.height)<=320,"RAW thumbnail is decoded and bounded")
    let canvas = PhotoScroll(frame: NSRect(x: 0,y: 0,width: 1000,height: 700)); canvas.load(orphan)
    for _ in 0..<500 { if !canvas.loading { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    canvas.focusZoom(); try require(!canvas.fit && canvas.pixelSize.width == 8256,"RAW canvas supports focus 100% using native pixels")
    model.reject(stage: true); try await settled()
    try require(model.photos.count == 3 && model.poolRawPhotos.count == 1 && model.poolPhotos.isEmpty,"RAW-only W stages orphan RAW without phantom JPEG")
    await model.scan(); model.switchPool(true)
    try require(model.photos.count == 1 && model.currentPath?.contains("DRaw") == true,"RAW pool survives rescan and remains viewable")
    model.handleKey(13); try await settled(); model.switchPool(false); model.selectPhoto(orphan)
    try require(model.currentPath == orphan && fm.fileExists(atPath: orphan),"W restores the recorded original path before trash test")
    model.remove(); try await settled(); try require(!fm.fileExists(atPath: orphan),"RAW-only S trashes the RAW")
    model.restore(); try await settled(); try require(fm.fileExists(atPath: orphan),"RAW-only undo restores original file")
    let canonicalRoot = URL(fileURLWithPath: model.root)
    let pairRAW = canonicalRoot.appendingPathComponent("Pair.NEF").path, pairJPEG = canonicalRoot.appendingPathComponent("Pair.JPG").path
    model.selectPhoto(pairRAW); model.reject(stage: true); try await settled()
    model.deleteMode = "仅 JPEG"; try require(model.photos.count == 3 && model.photos.first { $0.jpeg == pairJPEG }?.raw == nil,"moving RAW leaves its JPEG visible and unpaired")
    model.deleteMode = "JPEG + RAW"; try require(model.photos.isEmpty,"pair scope becomes empty after one side leaves; mode controls must remain available")
    model.deleteMode = "仅 RAW"; model.switchPool(true); model.returnFromPool(all: true); try await settled(); model.switchPool(false)
    model.deleteMode = "JPEG + RAW"; try require(model.photos.count == 1,"restoration re-establishes verified pair scope")
    model.reject(stage: true); try await settled(); model.switchPool(true)
    model.deleteMode = "仅 JPEG"
    model.handleKey(13); try await settled()
    try require(fm.fileExists(atPath: pairJPEG) && !fm.fileExists(atPath: pairRAW) && model.poolRawPhotos.count == 1 && model.poolBatches.first?.entries.count == 1,"W in pool restores only files in the selected scope and keeps remaining journal mapping")
    model.deleteMode = "仅 RAW"
    let pendingRAW = model.currentPath!
    model.handleKey(1); try await settled()
    try require(!fm.fileExists(atPath: pendingRAW) && !fm.fileExists(atPath: pairRAW),"S in pool trashes the staged file instead of restoring it")
    model.restore(); try await settled(); model.handleKey(13); try await settled()
    try require(fm.fileExists(atPath: pairRAW) && model.poolBatches.isEmpty,"undo S and then W works after partial pair restore")
    let manualPool = canonicalRoot.appendingPathComponent("DJpgManual")
    try fm.createDirectory(at: manualPool, withIntermediateDirectories: true)
    let manual = manualPool.appendingPathComponent("Manual.JPG")
    try fm.copyItem(at: URL(fileURLWithPath: pairJPEG), to: manual)
    await model.scan()
    model.deleteMode = "仅 JPEG"; model.selectPhoto(manual.path); model.handleKey(13); try await settled()
    try require(fm.fileExists(atPath: canonicalRoot.appendingPathComponent("JpgManual/Manual.JPG").path) && !fm.fileExists(atPath: manual.path),"W restores an unjournaled D folder entry to its matching formal folder")
    let broken = root.appendingPathComponent("broken.NEF"); try Data("invalid".utf8).write(to: broken)
    canvas.load(broken.path)
    for _ in 0..<500 { if !canvas.loading { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try require(!canvas.loading && !canvas.failureLabel.isHidden,"unsupported or damaged RAW shows an explicit failure instead of another photo")
    print(String(format: "PASS viewing scopes: JPEG 3 / RAW 4 / verified pairs 1; orphan, ambiguity, physical pool isolation, rescan, W/S/undo/restore; full Nikon RAW 8256×5504 %.2f ms, bounded thumbnail, histogram and focus 100%%, decode failure",rawTime))
}

@MainActor func runBurstAndScrubberTests(_ originals: URL, temp: URL) async throws {
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw FileActions.failure("FAIL: "+message) }
    }
    let frames = (920...922).map { String(format: "DSC_%04d", $0) }
    let badgePhoto = Photo(jpeg: originals.appendingPathComponent("DSC_0920.JPG").path, raw: nil, status: "仅 JPEG", source: "test")
    let badgeTile = FilmstripTile(path: badgePhoto.jpeg)
    badgeTile.place(CGRect(x: 0,y: 0,width: 80,height: 72), animated: false)
    badgeTile.decorate(FilmstripEntry(photo: badgePhoto,index: 0,burstCount: 3),current: true,dark: false)
    try require(badgeTile.burstBadgeLayer.string as? String == "×3" && !badgeTile.burstBadgeLayer.isHidden,"collapsed group shows count in a thumbnail corner badge")
    badgeTile.decorate(FilmstripEntry(photo: badgePhoto,index: 0,burstCount: 3,burstFrame: 1),current: true,dark: false)
    try require(badgeTile.burstBadgeLayer.string as? String == "1/3" && badgeTile.numberLayer.string as? String == "1", "expanded group shows frame ordinal separately from thumbnail index")
    let ids = frames.flatMap { stem in ["JPG", "NEF"].map { BurstMetadata.read(originals.appendingPathComponent("\(stem).\($0)").path) } }
    try require(ids.allSatisfy { $0 != nil } && Set(ids.compactMap { $0 }).count == 1, "real Z8 burst is identified across JPEG and NEF")
    try require(BurstMetadata.read(originals.appendingPathComponent("DSC_0926.JPG").path) != ids.first!, "unrelated frame is outside the real burst")
    let realID = ids.compactMap { $0 }.first!
    let secondID = BurstID(camera: realID.camera, start: realID.start, shutter: realID.shutter+100)
    let groupIDs = ["a1": realID, "a2": realID, "b1": secondID, "b2": secondID]
    let mixed = BurstMetadata.collapsed(["a1","a2","b1","b2"], ids: groupIDs,
                                        isCollapsed: { $0 == realID }, preferred: { _ in "a2" }, path: { $0 })
    try require(mixed == ["a2","b1","b2"], "a single collapsed group keeps its representative and leaves another group expanded")

    let scope = "Filter-burst-"+UUID().uuidString, preferences = UserDefaults(suiteName: scope)!
    defer { preferences.removePersistentDomain(forName: scope) }
    let model = Model(preferences: preferences, journal: temp.appendingPathComponent("burst-trash.json"))
    model.root = originals.path; model.page = 1
    model.activePhotos = (frames + ["DSC_0926"]).map { stem in
        Photo(jpeg: originals.appendingPathComponent(stem+".JPG").path, raw: originals.appendingPathComponent(stem+".NEF").path, status: "已配对", source: "test")
    }
    model.activeRawPhotos = model.activePhotos
    model.index = 1
    let current = model.currentPath
    model.handleKey(11)
    for _ in 0..<400 where model.scanningBursts { try await Task.sleep(nanoseconds: 10_000_000) }
    try require(model.burstsCollapsed && model.photos.count == 2 && model.currentPath == current && model.activePhotos.count == 4,"B folds real burst, preserving selected frame and underlying inventory")
    let track = FilmstripTrackView(frame: CGRect(x: 0,y: 0,width: 720,height: 102))
    let window = NSWindow(contentRect: track.frame,styleMask: [.borderless],backing: .buffered,defer: false)
    window.contentView = track
    track.reduceMotion = true; track.photoCount = model.photos.count
    track.onToggleBurst = model.toggleBurst; track.onSelect = model.selectPhoto
    track.update([FilmstripEntry(photo: model.current!,index: model.index,burstCount: 3)],index: model.index,departures: [],dark: false)
    let tile = track.tiles[current!]!
    let badge = tile.burstBadgeLayer.frame
    let badgePoint = tile.convert(CGPoint(x: badge.midX,y: badge.midY),to: nil)
    func mouse(_ kind: NSEvent.EventType, _ location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: kind,location: location,modifierFlags: [],timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 0,clickCount: 1,pressure: 1)!
    }
    tile.mouseDown(with: mouse(.leftMouseDown,badgePoint))
    tile.mouseDragged(with: mouse(.leftMouseDragged,CGPoint(x: badgePoint.x-35,y: badgePoint.y)))
    tile.mouseUp(with: mouse(.leftMouseUp,badgePoint))
    try require(model.photos.count == 2, "dragging from a burst badge does not toggle it")
    tile.mouseDown(with: mouse(.leftMouseDown,badgePoint)); tile.mouseUp(with: mouse(.leftMouseUp,badgePoint))
    try require(model.photos.count == 4 && !model.isBurstCollapsed(realID) && model.burstsCollapsed && model.currentPath == current, "badge opens only its group without changing the global setting or current photo")
    model.handleKey(11)
    try require(!model.burstsCollapsed && model.photos.count == 4 && model.currentPath == current,"B unfolds and retains current frame")
    model.selectIndex(3)
    let single = model.currentPath
    try require(model.toggleBurst(current!) && model.photos.count == 2 && model.photos.first?.jpeg == current && model.currentPath == single, "folding a nearby group keeps the current photo and uses the clicked frame as representative")
    model.handleKey(11); model.handleKey(11)
    try require(model.photos.count == 4 && model.currentPath == single, "global switch clears individual overrides and preserves the current photo")

    let count = 1000
    model.activePhotos += (model.activePhotos.count..<count).map { i in
        Photo(jpeg: "/unread-test/photo-\(i).JPG", raw: nil, status: "仅 JPEG", source: "test")
    }
    model.deleteMode = "仅 JPEG"
    let target = FilmstripScrubber.target(x: 540, width: 600, count: count)
    model.selectIndex(target)
    try require(model.index == 899 && model.current?.name == "photo-899.JPG", "90% scrub lands on frame 900 of 1000")
    try require(FilmstripScrubber.target(x: -20, width: 600, count: count) == 0 && FilmstripScrubber.target(x: 750, width: 600, count: count) == 999, "scrub clamps both ends")
    print("PASS Nikon burst B fold/unfold, independent native badge click versus drag, selection preserved; scrubber selects frame 900/1000 and clamps ends")
}

@MainActor func runFilmstripTests(_ originals: URL, temp: URL) async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw FileActions.failure("FAIL: " + message) } }
    let suite = "Filter-filmstrip-"+UUID().uuidString
    let isolated = UserDefaults(suiteName: suite)!
    defer { isolated.removePersistentDomain(forName: suite) }
    let model = Model(preferences: isolated, journal: temp.appendingPathComponent("filmstrip-trash.json"))
    model.startProjectMonitoring()
    defer { model.stopProjectMonitoring() }
    let files = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
    model.activePhotos = files.map { Photo(jpeg: $0.path, raw: $0.deletingPathExtension().appendingPathExtension("NEF").path, status: "已配对", source: "test") }; model.activeRawPhotos = model.activePhotos; model.page = 1; model.index = 3
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1280,height: 840), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Filter · 缩略图与对焦点保持测试"
    struct AppearanceProbe: View {
        @Environment(\.colorScheme) var scheme
        let observe: (ColorScheme) -> Void
        var body: some View { Color.clear.onChange(of: scheme, initial: true) { _, value in observe(value) } }
    }
    var observedScheme: ColorScheme?
    let originalAppearance = app.appearance
    let host = NSHostingView(rootView: ContentView().environmentObject(model).background {
        AppearanceProbe { observedScheme = $0 }
    })
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); app.appearance = originalAppearance; if let token = model.keyMonitor { NSEvent.removeMonitor(token) } }
    func findScroll(_ view: NSView) -> PhotoScroll? { if let scroll = view as? PhotoScroll { return scroll }; return view.subviews.lazy.compactMap { findScroll($0) }.first }
    func findTrack(_ view: NSView) -> FilmstripTrackView? { if let track = view as? FilmstripTrackView { return track }; return view.subviews.lazy.compactMap { findTrack($0) }.first }
    func settled(_ check: () -> Bool) async throws {
        for _ in 0..<500 { if check() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw FileActions.failure("filmstrip/focus UI timeout")
    }
    try await settled { findScroll(host).map { !$0.loading && $0.path == model.current?.jpeg } ?? false }
    try await settled { observedScheme != nil }
    let initialScheme = observedScheme!, alternateScheme: ColorScheme = initialScheme == .dark ? .light : .dark
    let photoBeforeToggle = model.currentPath
    try require(model.appearance == .system && app.appearance == nil, "new preferences inherit system appearance")
    model.toggleAppearance(from: initialScheme)
    try await settled { observedScheme == alternateScheme }
    try require(Model(preferences: isolated).appearance == model.appearance && model.currentPath == photoBeforeToggle, "app theme is saved and preserves displayed photo")
    let alternateWindowTheme: NSAppearance.Name = alternateScheme == .dark ? .darkAqua : .aqua
    try require(window.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == alternateWindowTheme, "native window follows SwiftUI theme")
    model.toggleAppearance(from: alternateScheme)
    try await settled { observedScheme == initialScheme }
    print("PASS appearance: system default, live SwiftUI/AppKit light/dark toggles, saved preference and unchanged photo")
    let scroll = findScroll(host)!
    for (mode,hue) in [("仅 JPEG",FilterPalette.green),("仅 RAW",.yellow),("JPEG + RAW",.red)] {
        model.deleteMode = mode
        try await settled { findTrack(host)?.selectionHue == hue }
        try require(Model(preferences: isolated).deleteMode == mode,"delete scope survives restart together with its status color")
        guard let track = findTrack(host),let tile = track.tiles[model.currentPath!] else { throw FileActions.failure("missing selected glow tile") }
        try require(tile.glowLayer.opacity == 1 && tile.glassRim.opacity == 1 && tile.glowLayer.shadowColor == FilterPalette.ns(hue.hex[0]).cgColor,"selected thumbnail glow follows \(mode) without changing photo")
        try require(tile.glowLayer.shadowRadius >= 8 && tile.rimMask.path != nil && tile.glowLayer.bounds == tile.imageLayer.bounds && tile.glassRim.bounds == tile.imageLayer.bounds,"soft halo and reflection share one exact image contour")
        let hover = NSEvent.enterExitEvent(with: .mouseEntered,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 0,trackingNumber: 0,userData: nil)!
        tile.mouseEntered(with: hover)
        try require(CATransform3DEqualToTransform(tile.imageLayer.transform,tile.glassRim.transform) && CATransform3DEqualToTransform(tile.imageLayer.transform,tile.glowLayer.transform),"hover never separates reflection and image edges")
        tile.mouseExited(with: hover)
        try require(track.tiles.filter { $0.key != model.currentPath! }.allSatisfy { $0.value.glowLayer.opacity == 0 && $0.value.glassRim.opacity == 0 },"only the current thumbnail glows")
        tile.reduceMotion = true
        let entry = track.entries.first { $0.id == tile.path }!
        tile.decorate(entry,current: true,dark: false,selectionHue: hue)
        try require(tile.glowLayer.animation(forKey: "breathe") == nil && tile.glowLayer.opacity == 1,"reduced motion keeps static colored glass without breathing")
    }
    let glowStart = model.index, oldGlowPath = model.current!.jpeg
    model.step(1)
    try await settled { findTrack(host)?.tiles[model.current!.jpeg]?.glowLayer.opacity == 1 && findTrack(host)?.tiles[oldGlowPath]?.glowLayer.opacity == 0 }
    model.selectIndex(glowStart)
    try await settled { findTrack(host)?.tiles[oldGlowPath]?.glowLayer.opacity == 1 }
    print("PASS filmstrip state light: JPEG green / RAW yellow / both red, same-photo mode updates, selected-only halo and reflective rim, reduced-motion static fallback")
    for size in [NSSize(width: 1000,height: 680),NSSize(width: 1280,height: 840)] {
        window.setContentSize(size); model.exif = true
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        guard let track = findTrack(host) else { throw FileActions.failure("missing filmstrip in layout check") }
        let pictureRect = scroll.convert(scroll.bounds,to: host), stripRect = track.convert(track.bounds,to: host)
        try require(!pictureRect.intersects(stripRect) && pictureRect.width>200 && pictureRect.height>200,"photo and filmstrip have disjoint usable regions at \(size)")
        try require(pictureRect.maxX <= host.bounds.maxX-264 && stripRect.maxX <= host.bounds.maxX-264,"photo and filmstrip both reserve the inspector column at \(size)")
        model.exif = false; try await Task.sleep(nanoseconds: 80_000_000); host.layoutSubtreeIfNeeded()
        try require(scroll.convert(scroll.bounds,to: host).width>pictureRect.width+200,"closing inspector returns its space to the image")
    }
    print("PASS viewer layout: 1000×680 / 1280×840, inspector on/off; photo, filmstrip and inspector reserve disjoint regions")
    model.collapsed = true; model.exif = true; window.setContentSize(NSSize(width: 1000,height: 680))
    try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
    let compactPicture = scroll.convert(scroll.bounds,to: host), compactStrip = findTrack(host)!.convert(findTrack(host)!.bounds,to: host)
    try require(!compactPicture.intersects(compactStrip) && compactPicture.maxX <= host.bounds.maxX-264 && compactStrip.maxX <= host.bounds.maxX-264,"collapsed sidebar also preserves all three regions")
    model.collapsed = false; model.exif = false; window.setContentSize(NSSize(width: 1280,height: 840))
    try await Task.sleep(nanoseconds: 150_000_000)
    func centeredOnCurrentFocus() -> Bool {
        guard let path = model.current?.jpeg, scroll.path == path, !scroll.loading, let point = scroll.focus else { return false }
        return !scroll.fit && abs(scroll.magnification-1/window.backingScaleFactor)<0.0001 && abs(scroll.contentView.bounds.midX-point.x*scroll.pixelSize.width)<2 && abs(scroll.contentView.bounds.midY-(1-point.y)*scroll.pixelSize.height)<2
    }
    model.handleKey(29); try await settled { centeredOnCurrentFocus() }
    try require(model.focusTracking && scroll.focusTracking,"0 enables shared focus tracking")
    for delta in [1,-1,2,-2] { model.step(delta); try await settled { centeredOnCurrentFocus() } }
    let neighbor = model.photos[model.index+1].jpeg
    try require(findTrack(host)?.tiles[neighbor]?.accessibilityPerformPress() == true,"native thumbnail supports press")
    try await settled { model.current?.jpeg == neighbor && centeredOnCurrentFocus() }
    // Send native mouse events through a tile, including release after it moves.
    let track = findTrack(host)!
    func mouse(_ kind: NSEvent.EventType,_ x: CGFloat) -> NSEvent { NSEvent.mouseEvent(with: kind,location: NSPoint(x: x,y: 60),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 0,clickCount: 1,pressure: 1)! }
    let dragStart = model.index, startTile = track.tiles[model.current!.jpeg]!, stride = track.tileSize.width+9
    startTile.mouseDown(with: mouse(.leftMouseDown,400)); startTile.mouseDragged(with: mouse(.leftMouseDragged,400-stride*2))
    try await settled { model.index == min(model.photos.count-1,dragStart+2) && centeredOnCurrentFocus() }
    startTile.mouseUp(with: mouse(.leftMouseUp,400-stride*2))
    try require(model.index == min(model.photos.count-1,dragStart+2),"drag release never clicks the old thumbnail")
    track.mouseDown(with: mouse(.leftMouseDown,300)); track.mouseDragged(with: mouse(.leftMouseDragged,300+stride*2)); track.mouseUp(with: mouse(.leftMouseUp,300+stride*2))
    try await settled { model.index == dragStart && centeredOnCurrentFocus() }
    track.mouseDown(with: mouse(.leftMouseDown,300)); track.mouseDragged(with: mouse(.leftMouseDragged,300+stride*100)); track.mouseUp(with: mouse(.leftMouseUp,300+stride*100))
    try await settled { model.index == 0 && centeredOnCurrentFocus() }
    let wheel = CGEvent(scrollWheelEvent2Source: nil,units: .pixel,wheelCount: 2,wheel1: 0,wheel2: -Int32(stride*2),wheel3: 0)!
    track.scrollWheel(with: NSEvent(cgEvent: wheel)!)
    try await settled { model.index == 2 && centeredOnCurrentFocus() }
    try await Task.sleep(nanoseconds: 200_000_000)
    model.selectIndex(dragStart); try await settled { centeredOnCurrentFocus() }
    print("PASS filmstrip navigation: native tile drag forward/back, no click after drag, edge clamp, horizontal pixel scroll, focus tracking preserved")
    for _ in 0..<15 { model.step(1); model.step(-1) }
    try await settled { centeredOnCurrentFocus() }
    model.handleKey(42, characters: "、"); model.step(1)
    try await settled { scroll.path == model.current?.jpeg && !scroll.loading && scroll.fit }
    try require(!model.focusTracking && !scroll.focusTracking,"manual fit exits tracking for following images")
    scroll.toggleZoom(at: NSPoint(x: 3000,y: 2000)); model.step(-1)
    try await settled { scroll.path == model.current?.jpeg && !scroll.loading && scroll.fit }
    try require(!model.focusTracking,"ordinary zoom retains fit-on-switch behavior")
    model.focusCurrent(); try await settled { centeredOnCurrentFocus() }
    scroll.toggleZoom(at: .zero)
    try await settled { !model.focusTracking && scroll.fit }
    model.focusCurrent(); model.step(1); model.fitCurrent()
    try await settled { scroll.path == model.current?.jpeg && !scroll.loading && scroll.fit && !scroll.focusTracking }

    let noAF = temp.appendingPathComponent("no-af.JPG")
    let thumbnail: CGImage? = await withCheckedContinuation { continuation in ThumbnailStore.shared.load(files[3].path) { continuation.resume(returning: $0) } }
    guard let thumbnail else { throw FileActions.failure("thumbnail decode") }
    try require(max(thumbnail.width,thumbnail.height)<=320,"filmstrip only decodes bounded thumbnails")
    let destination = CGImageDestinationCreateWithURL(noAF as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination,thumbnail,nil); try require(CGImageDestinationFinalize(destination),"metadata-free test image created")
    let valid = model.current!.jpeg
    model.deleteMode = "仅 JPEG"
    model.activePhotos.append(Photo(jpeg: noAF.path,raw: nil,status: "仅 JPEG",source: "test"))
    model.focusCurrent(); model.selectPhoto(noAF.path)
    try await settled { scroll.path == noAF.path && !scroll.loading && !scroll.fit && model.viewportLabel == "中心 100%" }
    try require(model.focusTracking && abs(scroll.magnification-1/window.backingScaleFactor)<0.00001 && abs(scroll.contentView.bounds.midX-scroll.pixelSize.width/2)<2 && abs(scroll.contentView.bounds.midY-scroll.pixelSize.height/2)<2,"unavailable focus centers true 100% without clearing tracking intent")
    model.selectPhoto(valid); try await settled { centeredOnCurrentFocus() }
    model.fitCurrent()
    model.toggleFilmstrip(); try require(!model.filmstripVisible && !Model(preferences: isolated).filmstripVisible,"filmstrip switch persists")
    model.handleKey(17); try require(model.filmstripVisible && Model(preferences: isolated).filmstripVisible,"T reopens persistent filmstrip")
    let sample = (0..<15).map { Photo(jpeg: "photo\($0).jpg",raw: nil,status: "仅 JPEG",source: "test") }
    let visible = filmstripEntries(sample,index: 7).filter { abs($0.index-7)<=3 }
    try require(visible.count==7 && visible.first?.index==4 && visible.last?.index==10 && visible[3].index==7,"current plus three on each side")
    try require(filmstripEntries(sample,index: 0).filter { $0.index<=3 }.count==4 && filmstripEntries([],index: 0).isEmpty,"edges and empty list remain bounded")
    model.root = originals.path; model.deleteMode = "仅 JPEG"; model.focusCurrent()
    let staged = model.current!.jpeg
    model.handleKey(13)
    let poolEvent = model.filmstripDepartures.last!.id
    try await settled { !model.working && centeredOnCurrentFocus() && findTrack(host)?.effectLayers[poolEvent] != nil }
    try require(!FileManager.default.fileExists(atPath: staged),"hosted W moves test JPEG while advancing in focus mode")
    model.returnFromPool(all: true); try await settled { !model.working && FileManager.default.fileExists(atPath: staged) }
    let deleted = model.current!.jpeg
    model.handleKey(1)
    let trashEvent = model.filmstripDepartures.last!.id
    try await settled { !model.working && centeredOnCurrentFocus() && findTrack(host)?.effectLayers[trashEvent]?.sublayers?.count == 70 }
    try require(!FileManager.default.fileExists(atPath: deleted),"hosted S trashes test JPEG while advancing in focus mode")
    model.restore(); try await settled { !model.working && FileManager.default.fileExists(atPath: deleted) }
    model.toggleFilmstrip(); model.handleKey(13)
    try require(model.filmstripDepartures.isEmpty,"hidden bar never queues effects")
    try await settled { !model.working }; model.returnFromPool(all: true); try await settled { !model.working }
    model.toggleFilmstrip(); model.fitCurrent()
    try renderFilmstripEffects(thumbnail)
    // View display links pause when occluded. Keep this test window visible
    // while measuring so another application's window cannot skew the result.
    window.level = .floating; window.orderFrontRegardless()
    try await Task.sleep(nanoseconds: 250_000_000)
    let idle = FilmstripDisplayProbe(model: model, view: host).run(idle: true)
    model.filmstripVisible = false
    let hidden = FilmstripDisplayProbe(model: model, view: host).run()
    model.filmstripVisible = true
    let moving = FilmstripDisplayProbe(model: model, view: host).run()
    try require(moving.p95 <= max(idle.p95,hidden.p95)+8 && moving.hz >= hidden.hz*0.85,"filmstrip must preserve baseline display cadence")
    print("PASS filmstrip: hosted focus tracking forward/back/rapid, exact 100%, click/fit reset, decode race, missing metadata recovery; seven slots, click selection, 320px cache, T/persistent visibility; W/S effects")
}

@MainActor func runImageSchedulingTests(_ jpeg: String) async throws {
    let store = ImageStore(); store.queue.isSuspended = true
    var cancelled = 0
    for path in ["obsolete-1","obsolete-2"] { store.load(path) { frame in if frame == nil { cancelled += 1 } } }
    store.cancelPending(except: [jpeg])
    try await Task.sleep(nanoseconds: 10_000_000)
    guard store.operations.isEmpty,store.waiting.isEmpty,cancelled == 2 else { throw FileActions.failure("rapid scrub must retire obsolete queued decodes and finish callbacks") }
    store.load(jpeg,prefetch: true)
    let queued = store.operations[jpeg]!
    guard queued.queuePriority == .low else { throw FileActions.failure("prefetch priority") }
    store.load(jpeg)
    guard store.operations[jpeg] === queued,queued.queuePriority == .veryHigh,store.queue.operations.filter({ !$0.isCancelled }).count == 1 else { throw FileActions.failure("visible image must promote and reuse queued prefetch") }
    store.queue.isSuspended = false
    let frame: ImageFrame? = await withCheckedContinuation { continuation in store.load(jpeg) { continuation.resume(returning: $0) } }
    guard let frame,store.operations.isEmpty,store.cache.totalCostLimit>=320*1024*1024,store.cache.totalCostLimit<=768*1024*1024 else { throw FileActions.failure("bounded decoded frame cache") }
    let cost45MP = 8256*5504*4
    if store.cache.totalCostLimit >= cost45MP*3 {
        store.cache.removeAllObjects()
        for key in ["previous","current","next"] { store.cache.setObject(frame,forKey: key as NSString,cost: cost45MP) }
        guard ["previous","current","next"].allSatisfy({ store.cache.object(forKey: $0 as NSString) != nil }) else { throw FileActions.failure("45 MP neighbor frames must fit the selected memory budget") }
    }
    print("PASS image scheduling: obsolete scrub decodes cancelled with completed callbacks, one shared decode, queued foreground promotion, cleaned requests, \(store.cache.totalCostLimit/1024/1024) MiB bounded cache for neighboring 45 MP frames")
}

@MainActor func runHistogramTests(_ jpeg: String) throws {
    func require(_ condition: @autoclosure () -> Bool,_ message: String) throws { if !condition() { throw FileActions.failure("FAIL: "+message) } }
    func image(_ bytes: [UInt8],width: Int,height: Int) -> CGImage {
        CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
    let chart = image([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255],width: 4,height: 1)
    let rgb = PhotoHistogram(image: chart)!
    func plotBackground(_ scheme: ColorScheme) -> CGFloat? {
        let render = ImageRenderer(content: HistogramPlot(histogram: rgb).frame(width: 236).environment(\.colorScheme, scheme))
        guard let image = render.cgImage,
              let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 14, y: image.height/2)?.usingColorSpace(.sRGB) else { return nil }
        return pixel.redComponent
    }
    try require((plotBackground(.light) ?? 0) > 0.90 && (plotBackground(.dark) ?? 1) < 0.30, "rendered histogram plot background follows light and dark modes")
    try require(rgb.sampleCount == 4 && rgb.channels.allSatisfy { $0.reduce(0,+) == 4 },"all four histogram channels conserve pixels")
    try require((0..<3).allSatisfy { rgb.channels[$0][255] == 2 && rgb.channels[$0][0] == 2 },"sRGB primary bins and byte order")
    try require([54,182,18,255].allSatisfy { rgb.channels[3][$0] == 1 },"white channel is Rec.709 luma")
    for value: UInt8 in [0,128,255] {
        let gray = PhotoHistogram(image: image([value,value,value,255],width: 1,height: 1))!
        try require(gray.channels.allSatisfy { $0[Int(value)] == 1 },"black, midtone and white endpoints")
        try require(gray.curves.allSatisfy { $0.count == 256 && $0.allSatisfy { $0.isFinite && $0>=0 && $0<=1 } },"bounded finite plot curves")
    }
    let large = PhotoHistogram(image: image(Array(repeating: [UInt8(128),128,128,255],count: 2048*1024).flatMap { $0 },width: 2048,height: 1024))!
    try require(large.sampleCount == 512*256 && large.channels[3][128] == large.sampleCount,"large images use bounded downsampling")
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: jpeg) as CFURL,nil)!
    let realImage = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 20000] as CFDictionary)!
    let start = CACurrentMediaTime(), real = PhotoHistogram(image: realImage)!
    let elapsed = (CACurrentMediaTime()-start)*1000
    try require(real.channels.allSatisfy { $0.reduce(0,+) == real.sampleCount } && real.channels[3].filter { $0>0 }.count>32,"real Nikon histogram has tonal data")
    let linear = real.curves, log = real.curves(logarithmic: true)
    try require(log.allSatisfy { $0.allSatisfy { $0.isFinite && $0>=0 && $0<=1 } },"log scale is finite and normalized")
    try require(zip(log.flatMap { $0 },linear.flatMap { $0 }).allSatisfy { $0+0.000001 >= $1 },"log scale expands low-frequency bins without moving tonal coordinates")
    let peak = real.channels.flatMap { $0 }.max()!, middle = real.channels[3][128]
    print("HISTOGRAM real Nikon: peak bin \(peak), luma bin128 \(middle), black \(real.channels[3][0])/\(real.sampleCount), white \(real.channels[3][255])/\(real.sampleCount); linear mid \(linear[3][128]), log mid \(log[3][128])")
    print(String(format: "PASS histogram: RGB byte order, Rec.709 white, shared normalization, black/gray/white endpoints, conserved counts, 512px bound; real Nikon %.2f ms",elapsed))
}

func runMetadataTests(_ jpeg: String,temp: URL) throws {
    func require(_ condition: @autoclosure () -> Bool,_ message: String) throws { if !condition() { throw FileActions.failure("FAIL: "+message) } }
    let bias = kCGImagePropertyExifExposureBiasValue as String, meter = kCGImagePropertyExifMeteringMode as String, flash = kCGImagePropertyExifFlash as String
    func rows(_ exif: [String: Any]) -> [String: String] { Dictionary(uniqueKeysWithValues: metadataRows([kCGImagePropertyExifDictionary as String: exif])) }
    for (value,text) in [(0.0,"0 EV"),(-0.0,"0 EV"),(-1.0/3,"-0.3 EV"),(2.0/3,"+0.7 EV"),(Double.nan,"未记录")] { try require(rows([bias: value])["曝光补偿"] == text,"signed exposure compensation and invalid values") }
    for (value,text) in [(0,"未知"),(1,"平均测光"),(2,"中央重点平均"),(3,"点测光"),(4,"多点测光"),(5,"矩阵／评价测光"),(6,"局部测光"),(255,"其他"),(17,"未知（17）")] { try require(rows([meter: value])["测光模式"] == text,"EXIF metering mode names") }
    for (value,text) in [(0,"未闪光"),(8,"未闪光"),(16,"未闪光"),(24,"未闪光"),(25,"已闪光"),(32,"无闪光功能"),(48,"无闪光功能"),(0x41,"已闪光"),(0x59,"已闪光"),(65535,"未知（65535）"),(-1,"未记录")] { try require(rows([flash: value])["闪光灯"] == text,"flash fired bit is separate from auto/on flags") }
    let missing = rows([:])
    try require(["曝光补偿","测光模式","闪光灯"].allSatisfy { missing[$0] == "未记录" },"missing EXIF must not claim zero EV or no flash")
    let captureTime = kCGImagePropertyExifDateTimeOriginal as String
    try require(rows([captureTime: "2026:11:01 14:01:39.29+08:00"])["拍摄时间"] == "2026-11-01 14:01:39.29+08:00", "format only the camera date prefix")
    try require(rows([captureTime: "2026-11-01T14:01:39"])["拍摄时间"] == "2026-11-01T14:01:39" && missing["拍摄时间"] == "—", "already formatted and missing capture dates retain their display")
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: jpeg) as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String: Any], let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { throw FileActions.failure("metadata fixture source") }
    let real = Dictionary(uniqueKeysWithValues: metadataRows(properties))
    try require(real["拍摄时间"] == "2026-11-01 14:01:39", "Nikon capture date uses hyphens and time uses colons")
    try require(["曝光补偿","测光模式","闪光灯"].allSatisfy { real[$0] != nil && real[$0] != "未记录" },"real Nikon JPEG exposes all three fields through ImageIO")
    let fixture = temp.appendingPathComponent("exposure-meter-flash.JPG")
    let destination = CGImageDestinationCreateWithURL(fixture as CFURL,"public.jpeg" as CFString,1,nil)!
    let fixtureExif: [String: Any] = [bias: 1.0/3,meter: 3,flash: 25]
    CGImageDestinationAddImage(destination,image,[kCGImagePropertyExifDictionary as String: fixtureExif] as CFDictionary)
    try require(CGImageDestinationFinalize(destination),"write EXIF fixture")
    let saved = CGImageSourceCreateWithURL(fixture as CFURL,nil)!
    let roundtrip = Dictionary(uniqueKeysWithValues: metadataRows(CGImageSourceCopyPropertiesAtIndex(saved,0,nil) as! [String: Any]))
    try require(roundtrip["曝光补偿"] == "+0.3 EV" && roundtrip["测光模式"] == "点测光" && roundtrip["闪光灯"] == "已闪光","real JPEG EXIF round trip: \(roundtrip)")
    print("PASS EXIF: capture date format, signed/zero/missing EV, metering modes, flash flags, actual JPEG round trip; real Nikon: \(real["拍摄时间"]!), \(real["曝光补偿"]!), \(real["测光模式"]!), \(real["闪光灯"]!)")
}

@MainActor func runProjectOrderingTests(_ temp: URL) async throws {
    func require(_ condition: @autoclosure () -> Bool,_ message: String) throws { if !condition() { throw FileActions.failure("FAIL: "+message) } }
    let suite = "Filter-project-order-"+UUID().uuidString, fm = FileManager.default
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = Model(preferences: preferences,journal: temp.appendingPathComponent("order-trash.json"))
    let directories = ["first","second","third","fourth"].map { temp.appendingPathComponent("order/"+$0) }
    for directory in directories {
        try fm.createDirectory(at: directory,withIntermediateDirectories: true)
        try fm.copyItem(at: temp.appendingPathComponent("exposure-meter-flash.JPG"),to: directory.appendingPathComponent("photo.JPG"))
    }
    let paths = directories.map { url -> String in
        guard let path = realpath(url.path,nil) else { return url.path }
        defer { free(path) }; return String(cString: path)
    }
    func settle() async throws {
        for _ in 0..<300 { if !model.working { if let error = model.error { throw FileActions.failure(error) }; return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw FileActions.failure("project ordering load timeout")
    }
    for path in paths.prefix(3) { model.open(path); try await settle() }
    model.open(paths[0]); try await settle()
    try require(model.projects.map(\.root) == Array(paths.prefix(3)),"opening an old project preserves addition order")
    await model.refreshProjects(only: paths[1])
    try require(model.projects.map(\.root) == Array(paths.prefix(3)) && model.root == paths[0],"refresh preserves order and active project")
    model.toggleProjectPin(paths[2]); try require(model.displayedProjects.map(\.root) == [paths[2],paths[0],paths[1]],"pinned project moves to first position")
    model.toggleProjectPin(paths[1]); try require(model.displayedProjects.map(\.root) == [paths[1],paths[2],paths[0]],"newly pinned project appears first")
    model.toggleProjectPin(paths[2]); model.toggleProjectPin(paths[1])
    try require(model.displayedProjects.map(\.root) == Array(paths.prefix(3)),"unpin restores original addition order")
    model.toggleProjectPin(paths[2]); model.open(paths[3]); try await settle()
    try require(model.projects.map(\.root) == paths && model.displayedProjects.map(\.root) == [paths[2],paths[0],paths[1],paths[3]],"new projects append after ordinary projects")
    model.toggleProjectPin(paths[0]); model.removeProject(paths[0])
    let restored = Model(preferences: preferences)
    try require(restored.pinnedProjects == [paths[2]] && restored.displayedProjects.map(\.root) == [paths[2],paths[1],paths[3]],"pin and addition order persist; deleting a pin cleans its state")
    model.removeProject(paths[2]); model.open(paths[2]); try await settle()
    try require(model.pinnedProjects.isEmpty && model.projects.map(\.root) == [paths[1],paths[3],paths[2]],"explicitly re-adding a removed project appends it without reviving a pin")
    model.projectSortDescending = true
    try require(model.displayedProjects.map(\.root) == [paths[2],paths[3],paths[1]],"reverse addition order")
    model.setProjectDate(Date(timeIntervalSince1970: 100), for: paths[3])
    model.setProjectDate(Date(timeIntervalSince1970: 200), for: paths[1])
    model.projectSort = .date
    await model.refreshProjects(only: paths[1])
    try require(model.displayedProjects.map(\.root) == [paths[1],paths[3],paths[2]],"custom timestamp sorts and survives project refresh, unset last")
    model.toggleProjectPin(paths[2])
    let reloaded = Model(preferences: preferences)
    try require(reloaded.projectSort == .date && reloaded.projectSortDescending && reloaded.displayedProjects.map(\.root) == [paths[2],paths[1],paths[3]],"date, sort direction, and pins persist in stable order")
    model.projects[0].sizes = ["project": 900]
    model.projects[1].sizes = ["project": 20]
    model.projectSort = .size; model.projectSortDescending = false
    try require(model.displayedProjects.map(\.root) == [paths[2],paths[3],paths[1]],"size ascending with pinned project at top")
    print("PASS project ordering: stable addition order on click/refresh, pin-first and multiple pins, unpin restoration, appended new projects, persistence and deletion cleanup")
}

@MainActor func runConnectionTests(_ temp: URL) async throws {
    func require(_ condition: @autoclosure () -> Bool,_ message: String) throws { if !condition() { throw FileActions.failure("FAIL: "+message) } }
    func settled(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw FileActions.failure("connection check timeout")
    }
    let fm = FileManager.default, volume = temp.appendingPathComponent("presence-volume")
    let live = volume.appendingPathComponent("unorganized"), missing = volume.appendingPathComponent("missing")
    let sibling = temp.appendingPathComponent("presence-volume-copy/project"), file = temp.appendingPathComponent("not-a-directory")
    try fm.createDirectory(at: live,withIntermediateDirectories: true); try fm.createDirectory(at: sibling,withIntermediateDirectories: true); try Data([1]).write(to: file)
    let suite = "Filter-presence-"+UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let model = Model(preferences: preferences,journal: temp.appendingPathComponent("presence-trash.json"))
    defer { model.stopProjectMonitoring(); preferences.removePersistentDomain(forName: suite) }
    model.projects = [live,missing,sibling,file].map { Project(root: $0.path,counts: ["jpg": 2],formats: ["JPG": 2],organized: false,updated: "cached",sizes: ["project": 1234]) }
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let cached = try encoder.encode(model.projects); preferences.set(cached,forKey: "projects")
    model.root = live.path; model.page = 1; model.activePhotos = [Photo(jpeg: live.appendingPathComponent("photo.JPG").path,raw: nil,status: "仅 JPEG",source: "test")]
    model.startProjectMonitoring(); let timer = model.connectionTimer
    model.startProjectMonitoring()
    try require(model.connectionTimer === timer && model.connectionObservers.count == 5,"monitoring is idempotent")
    try await settled { model.connectionProbes.isEmpty && model.connections.count == 4 }
    try require(model.connections[live.path] == .online && !model.projects[0].organized,"online is independent of organizer completion")
    try require(model.connections[missing.path] == .offline && model.connections[file.path] == .offline && model.connections[sibling.path] == .online,"missing directory and regular file are offline")
    let held = temp.appendingPathComponent("presence-held")
    try fm.moveItem(at: live,to: held); model.refreshProjectConnections()
    try await settled { model.connections[live.path] == .offline && model.connectionProbes.isEmpty }
    let oldPhoto = model.current
    model.open(live.path)
    try require(model.current == oldPhoto && model.error?.contains("离线") == true,"offline open preserves browsing context")
    model.error = nil; model.reject(stage: true)
    try require(model.current == oldPhoto && model.pending == 0 && model.filmstripDepartures.isEmpty,"offline W/S never removes cached photos or starts file operations")
    model.error = nil
    try fm.moveItem(at: held,to: live)
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.post(name: NSWorkspace.didMountNotification,object: nil,userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    try await settled { model.connections[live.path] == .online && model.connectionProbes.isEmpty }

    let ordinaryProbe = model.connectionProbe, began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    model.connectionProbe = { path in
        if path == live.path { began.signal(); _ = release.wait(timeout: .now()+2); return true }
        return ordinaryProbe(path)
    }
    model.refreshProjectConnections(only: live.path); let token = model.connectionProbes[live.path]
    model.refreshProjectConnections(only: live.path)
    try require(model.connectionProbes[live.path] == token,"repeated checks coalesce")
    try await settled { began.wait(timeout: .now()) == .success }
    workspace.post(name: NSWorkspace.didUnmountNotification,object: nil,userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    try await settled { model.connections[live.path] == .offline }
    try require(model.connections[sibling.path] == .online,"volume prefix does not mark another disk offline")
    release.signal(); try await Task.sleep(nanoseconds: 60_000_000)
    try require(model.connections[live.path] == .offline,"stale pre-unmount result cannot turn the dot green")
    model.connectionProbe = ordinaryProbe
    workspace.post(name: NSWorkspace.didMountNotification,object: nil,userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    try await settled { model.connections[live.path] == .online && model.connectionProbes.isEmpty }
    let after = try encoder.encode(model.projects)
    try require(after == cached,"online checks preserve cached counts sizes and project records")
    var publishes = 0
    let subscription = model.objectWillChange.sink { publishes += 1 }
    model.refreshProjectConnections(); try await settled { model.connectionProbes.isEmpty }
    subscription.cancel(); try require(publishes == 0,"unchanged probes do not repaint the interface")
    try require(Model(preferences: preferences).connections.isEmpty,"availability is checked live rather than persisted as stale green")
    model.removeProject(missing.path)
    try require(model.connections[missing.path] == nil,"removed projects have no retained connection status")

    for hue in FilterPalette.allCases {
        try require(hue.hex.count == 3,"three supplied swatches per color family")
        for dark in [false,true] {
            let background = FilterPalette.luminance(dark ? 0x151518 : 0xffffff), ink = FilterPalette.luminance(hue.inkHex(dark: dark))
            try require((max(ink,background)+0.05)/(min(ink,background)+0.05)>=4.5,"palette text remains readable in both themes")
        }
    }
    let light = ConnectionLight(frame: NSRect(x: 0,y: 0,width: 14,height: 14))
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 14,height: 14),styleMask: [],backing: .buffered,defer: false); window.contentView = light
    light.update(.online,reduced: false)
    try require(light.halo.animation(forKey: "breathe") != nil,"online indicator breathes on the compositor")
    light.update(.offline,reduced: false); try require(light.halo.animation(forKey: "breathe") == nil,"offline yellow stays steady")
    light.update(.online,reduced: true); try require(light.halo.animation(forKey: "breathe") == nil,"reduce motion stops breathing")
    print("PASS presence/palette: reachable/unorganized and offline paths, missing folder, mount/unmount recovery, stale-result guard, disk boundary, preserved cached records/context, coalesced checks, no idle repaints; 9 supplied color families, readable text, native breathing/reduced motion")
}

@MainActor final class FilmstripDisplayProbe: NSObject {
    let model: Model
    let view: NSView
    var times: [Double] = [], costs: [Double] = []
    var direction = 1
    var idle = false
    init(model: Model, view: NSView) { self.model = model; self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        let start = CACurrentMediaTime(); times.append(start)
        if !idle && times.count % 8 == 0 {
            if model.index >= model.photos.count-2 { direction = -1 }; if model.index <= 1 { direction = 1 }
            model.step(direction)
        }
        if !idle && model.filmstripVisible && times.count % 24 == 0, let photo = model.current {
            let event = FilmstripDeparture(path: photo.jpeg, image: ThumbnailStore.shared.cached(photo.jpeg), kind: times.count % 48 == 0 ? .trash : .pool)
            model.filmstripDepartures = [event]
        }
        costs.append((CACurrentMediaTime()-start)*1000)
    }
    func run(idle: Bool = false) -> (hz: Double,p95: Double) {
        self.idle = idle
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        let label = idle ? "IDLE" : model.filmstripVisible ? "MOVING" : "HIDDEN"
        let end = Date().addingTimeInterval(idle ? 2 : 3)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        link.invalidate(); model.filmstripDepartures = []
        let stable = Array(times.dropFirst(8)), intervals = zip(stable.dropFirst(),stable).map { ($0-$1)*1000 }.sorted()
        guard intervals.count > 30 else { print("FAIL filmstrip \(label) display callbacks: \(times.count)"); exit(1) }
        costs.sort()
        print(String(format: "FILMSTRIP \(label) DISPLAY %.1f Hz; frame interval p95 %.2f ms; navigation/effect state CPU p95 %.3f ms; %d callbacks", Double(stable.count-1)/(stable.last!-stable.first!), intervals[Int(Double(intervals.count)*0.95)], costs[Int(Double(costs.count)*0.95)], times.count))
        return (Double(stable.count-1)/(stable.last!-stable.first!),intervals[Int(Double(intervals.count)*0.95)])
    }
}

@MainActor func renderFilmstripEffects(_ image: CGImage) throws {
    let native = FilmstripTrackView(frame: NSRect(x: 0,y: 0,width: 720,height: 102))
    let shatter = FilmstripDeparture(path: "test",image: image,kind: .trash)
    native.update([],index: 0,departures: [shatter],dark: false)
    guard let layers = native.effectLayers[shatter.id]?.sublayers, layers.count == 70,
          layers.allSatisfy({ ($0.animation(forKey: "departure") as? CAAnimationGroup)?.duration == 0.44 && $0.contents != nil }) else { throw FileActions.failure("native shatter must contain 70 textured compositor animations") }
    let flight = FilmstripDeparture(path: "test",image: image,kind: .pool)
    native.update([],index: 0,departures: [flight],dark: false)
    let group = native.effectLayers[flight.id]!.sublayers!.first!.animation(forKey: "departure") as! CAAnimationGroup
    let path = (group.animations!.first as! CAKeyframeAnimation).values as! [NSValue]
    guard path.last!.pointValue.y < path.first!.pointValue.y-140, native.effectLayers[shatter.id] == nil else { throw FileActions.failure("native flight must go up and expired layers must be removed") }
    native.reduceMotion = true
    native.update([],index: 0,departures: [shatter],dark: false)
    guard native.effectLayers[shatter.id]?.sublayers?.count == 1 else { throw FileActions.failure("reduce-motion removes particle movement") }
    struct Pixels { var alpha: Double; var y: Double; var width: Int }
    func stats(_ image: CGImage) -> Pixels {
        let w=image.width,h=image.height; var bytes=[UInt8](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context=CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        var alpha=0.0,ySum=0.0,minX=w,maxX=0
        for y in 0..<h { for x in 0..<w { let a=Double(bytes[(y*w+x)*4+3]); alpha+=a; ySum+=Double(y)*a; if a>5 { minX=min(minX,x); maxX=max(maxX,x) } } }
        return Pixels(alpha:alpha,y:ySum/max(1,alpha),width:max(0,maxX-minX))
    }
    func render(_ kind: FilmstripDeparture.Kind,_ progress: Double,_ reduced: Bool=false) throws -> CGImage {
        let renderer=ImageRenderer(content:FilmstripDepartureDrawing(image:image,kind:kind,tileSize:CGSize(width:90,height:60),progress:progress,reduceMotion:reduced).frame(width:320,height:320)); renderer.scale=1
        guard let result=renderer.cgImage else { throw FileActions.failure("effect render failed") }; return result
    }
    let start=stats(try render(.trash,0)), middleImage=try render(.trash,0.45), middle=stats(middleImage), end=stats(try render(.trash,1))
    guard start.alpha>0,middle.alpha>0,middle.alpha<start.alpha,middle.width>start.width+35,end.alpha==0 else { throw FileActions.failure("shards must spread, fade and disappear") }
    let poolStart=stats(try render(.pool,0)), poolMiddle=try render(.pool,0.45), pool=stats(poolMiddle), reduced=stats(try render(.trash,0.45,true))
    guard abs(pool.y-poolStart.y)>45,pool.alpha<poolStart.alpha,abs(reduced.y-poolStart.y)<2 else { throw FileActions.failure("W must fly upward; reduce-motion must only fade") }
    for (name,frame) in [("Filmstrip-S-shatter.png",middleImage),("Filmstrip-W-flight.png",poolMiddle)] {
        let url=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/"+name)
        let dest=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,frame,nil); guard CGImageDestinationFinalize(dest) else { throw FileActions.failure("write effect preview") }
    }
    print("PASS thumbnail animation pixels: 70 textured shards expand/fade, upward flight, zero final alpha, reduced-motion fallback")
}

@MainActor func runVisualChecks() async throws {
    let app=NSApplication.shared; app.setActivationPolicy(.accessory)
    let source=CommandLine.arguments.last!
    let suite="Filter-visual-"+UUID().uuidString
    let preferences=UserDefaults(suiteName:suite)!
    let model=Model(preferences:preferences)
    model.open(source)
    for _ in 0..<500 { if !model.working { break }; try await Task.sleep(nanoseconds:20_000_000) }
    if let error=model.error { throw FileActions.failure(error) }
    let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build")
    func pump() { let end=Date().addingTimeInterval(0.5); while Date()<end { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) } }
    let checkPicker = CommandLine.arguments.contains("--folder-picker")
    for scheme in [ColorScheme.light, .dark] {
        var pickerFrame = CGRect.zero
        var pickerOpen: Binding<Bool>?
        let watch: ((CGRect, Binding<Bool>) -> Void)? = checkPicker ? { pickerFrame = $0; pickerOpen = $1 } : nil
        let view=NSHostingView(rootView:ContentView(observeFolderPicker: watch).environmentObject(model).environment(\.colorScheme,scheme))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:960),styleMask:[.titled],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:scheme == .light ? .aqua : .darkAqua)
        window.contentView=view; window.title="Filter appearance QA"; window.makeKeyAndOrderFront(nil)
        if checkPicker {
            app.activate()
            model.page = 1; model.exif = true; model.deleteMode = "仅 JPEG"
            model.prefetch()
            try await Task.sleep(nanoseconds: 600_000_000)
            for width in [1000, 1280] {
                window.setContentSize(NSSize(width: width, height: 710))
                window.center(); pump(); view.layoutSubtreeIfNeeded()
                guard let pickerOpen, (144...214).contains(pickerFrame.width.rounded()), view.bounds.contains(pickerFrame) else {
                    throw FileActions.failure("Directory trigger is clipped at \(scheme) \(width): \(pickerFrame)")
                }
                let previouslyVisible = Set(app.windows.filter(\.isVisible).map(\.windowNumber))
                pickerOpen.wrappedValue = true
                pump()
                let windows = (window.childWindows ?? []) + app.windows
                guard let panelWindow = windows.first(where: { $0.isVisible && !previouslyVisible.contains($0.windowNumber) && $0.frame.width >= 368 }) else {
                    throw FileActions.failure("Directory popover did not open at \(scheme) \(width): \(pickerFrame)")
                }
                for (part, target) in [("toolbar", window), ("panel", panelWindow)] {
                    let path = output.appendingPathComponent("folder-\(scheme)-\(width)-\(part).png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(target.windowNumber), path.path]
                    try capture.run(); capture.waitUntilExit()
                    if capture.terminationStatus != 0 { print("Window capture unavailable for \(part)") }
                }
                pickerOpen.wrappedValue = false
                pump()
            }
            print("PASS directory toolbar width and native popover in \(scheme), at 1000 and 1280 points")
            window.orderOut(nil)
            continue
        }
        // cacheDisplay does not capture the native CALayer image surface or
        // glass compositor. Verify the viewer in its actual running window.
        for page in [0] {
            model.page=page; pump(); view.layoutSubtreeIfNeeded()
            guard let image=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw FileActions.failure("preview render") }
            view.cacheDisplay(in:view.bounds,to:image)
            let name="UI-\(scheme == .light ? "light" : "dark")-\(page == 0 ? "organizer" : "viewer").png"
            try image.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }
    if let token=model.keyMonitor { NSEvent.removeMonitor(token) }
    preferences.removePersistentDomain(forName:suite)
    if !checkPicker { print("Rendered light/dark organizer previews; viewer requires live compositor verification") }
}
