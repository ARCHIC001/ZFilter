import SwiftUI
import AppKit
import ImageIO
import QuartzCore

final class ImageFrame {
    let image: CGImage
    let rows: [(String, String)]
    let recordedFocus: RecordedFocus
    let pictureControl: NikonPictureControl?
    var focus: FocusPoint? { recordedFocus.point }
    let histogram: PhotoHistogram?
    init(_ image: CGImage, _ rows: [(String, String)], focus: RecordedFocus, pictureControl: NikonPictureControl?) {
        self.image = image; self.rows = rows; recordedFocus = focus; self.pictureControl = pictureControl
        histogram = PhotoHistogram(image: image)
    }
}
final class ImageStore {
    static let shared = ImageStore()
    let cache = NSCache<NSString, ImageFrame>()
    let queue = OperationQueue()
    let lock = NSLock()
    var waiting: [String: [(ImageFrame?) -> Void]] = [:]
    var operations: [String: BlockOperation] = [:]
    private var operationIDs: [String: UUID] = [:]
    init() {
        // Keep current/previous/next 45 MP frames on this Mac without making
        // machines with less memory reserve the same amount.
        let memoryBudget = Int(min(ProcessInfo.processInfo.physicalMemory/24, UInt64(768 * 1024 * 1024)))
        cache.totalCostLimit = max(320 * 1024 * 1024, memoryBudget)
        cache.countLimit = 3; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
    }
    func load(_ path: String, prefetch: Bool = false, completion: @escaping (ImageFrame?) -> Void = { _ in }) {
        if let frame = cache.object(forKey: path as NSString) { DispatchQueue.main.async { completion(frame) }; return }
        lock.lock()
        if waiting[path] != nil {
            if !prefetch { operations[path]?.queuePriority = .veryHigh }
            waiting[path]!.append(completion); lock.unlock(); return
        }
        waiting[path] = [completion]
        let requestID = UUID(); operationIDs[path] = requestID
        let operation = BlockOperation {
            let frame: ImageFrame? = autoreleasepool {
                guard let decoded = MediaDecoder.decode(path) else { return nil }
                let metadata = FocusMetadata.recorded(path)
                var focus = metadata.focus
                let exif = decoded.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
                if focus.distance == nil, let meters = (exif?[kCGImagePropertyExifSubjectDistance as String] as? NSNumber)?.doubleValue, meters > 0 {
                    focus.distance = meters >= Double(UInt32.max) ? .infinity : meters
                }
                return ImageFrame(decoded.image, metadataRows(decoded.properties), focus: focus, pictureControl: metadata.pictureControl)
            }
            if let frame { self.cache.setObject(frame, forKey: path as NSString, cost: frame.image.bytesPerRow * frame.image.height) }
            self.lock.lock()
            let current = self.operationIDs[path] == requestID
            let completions = current ? self.waiting.removeValue(forKey: path) ?? [] : []
            if current { self.operations.removeValue(forKey: path); self.operationIDs.removeValue(forKey: path) }
            self.lock.unlock()
            DispatchQueue.main.async { completions.forEach { $0(frame) } }
        }
        operation.queuePriority = prefetch ? .low : .veryHigh
        operations[path] = operation; lock.unlock()
        queue.addOperation(operation)
    }
    func invalidate(_ path: String) { cache.removeObject(forKey: path as NSString) }
    func cancelPending(except paths: Set<String>) {
        lock.lock()
        var callbacks: [(ImageFrame?) -> Void] = []
        for path in Array(operations.keys) where !paths.contains(path) {
            guard let operation = operations[path],!operation.isExecuting else { continue }
            operation.cancel(); operations.removeValue(forKey: path); operationIDs.removeValue(forKey: path)
            callbacks += waiting.removeValue(forKey: path) ?? []
        }
        lock.unlock()
        if !callbacks.isEmpty { DispatchQueue.main.async { callbacks.forEach { $0(nil) } } }
    }
}
func metadataRows(_ p: [String: Any]) -> [(String, String)] {
    let ex = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    func value(_ dict: [String: Any], _ key: String) -> String { dict[key].map { String(describing: $0) } ?? "—" }
    var captureTime = value(ex, kCGImagePropertyExifDateTimeOriginal as String)
    if let date = captureTime.range(of: #"^[0-9]{4}:[0-9]{2}:[0-9]{2}(?=[ T]|$)"#, options: .regularExpression) {
        let formattedDate = captureTime[date].replacingOccurrences(of: ":", with: "-")
        captureTime.replaceSubrange(date, with: formattedDate)
    }
    var shutter = "—"
    if let t = ex["ExposureTime"] as? Double, t > 0 { shutter = t < 1 ? "1/\(Int((1/t).rounded())) s" : "\(t) s" }
    var compensation = "未记录"
    if let bias = (ex[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber)?.doubleValue, bias.isFinite {
        compensation = abs(bias)<0.0001 ? "0 EV" : String(format: "%+.1f EV",locale: Locale(identifier: "en_US_POSIX"),bias)
    }
    func code(_ key: CFString) -> Int? {
        guard let number = ex[key as String] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite,value>=0,value<=65535,value.rounded()==value else { return nil }; return Int(value)
    }
    let meteringNames = [0: "未知",1: "平均测光",2: "中央重点平均",3: "点测光",4: "多点测光",5: "矩阵／评价测光",6: "局部测光",255: "其他"]
    let metering = code(kCGImagePropertyExifMeteringMode).map { meteringNames[$0] ?? "未知（\($0)）" } ?? "未记录"
    var flash = "未记录"
    if let bits = code(kCGImagePropertyExifFlash) {
        // EXIF Flash is a bitfield: Auto/On alone does not mean it fired.
        flash = bits>127 ? "未知（\(bits)）" : bits & 1 != 0 ? "已闪光" : bits & 32 != 0 ? "无闪光功能" : "未闪光"
    }
    return [("相机", value(tiff, "Model")), ("镜头", value(ex, "LensModel")), ("拍摄时间", captureTime), ("光圈", "ƒ/" + value(ex, "FNumber")), ("快门", shutter), ("ISO", (ex["ISOSpeedRatings"] as? [Int])?.first.map(String.init) ?? "—"), ("曝光补偿", compensation), ("测光模式", metering), ("闪光灯", flash), ("焦距", value(ex, "FocalLength") + " mm"), ("分辨率", "\(value(p, "PixelWidth")) × \(value(p, "PixelHeight"))")]
}
final class CenterClip: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width)/2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height)/2 }
        }
        return rect
    }
}
final class ImageSurface: NSView {
    let focusOutline = CAShapeLayer()
    let focusBox = CAShapeLayer()
    weak var scroll: PhotoScroll?
    var start = NSPoint.zero
    var origin = NSPoint.zero
    var dragged = false
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize; layer?.minificationFilter = .trilinear; layer?.magnificationFilter = .linear
        layer?.masksToBounds = true
        focusOutline.fillColor = nil; focusOutline.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        focusBox.fillColor = nil; focusBox.strokeColor = FilterPalette.ns(0x51ef68).cgColor
        layer?.addSublayer(focusOutline); layer?.addSublayer(focusBox)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; origin = scroll?.contentView.bounds.origin ?? .zero; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        guard let scroll, !scroll.fit else { return }
        let point = event.locationInWindow
        let dx = point.x-start.x, dy = point.y-start.y
        if abs(dx)+abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        var proposed = scroll.contentView.bounds
        proposed.origin = NSPoint(x: origin.x-dx/scroll.magnification, y: origin.y-dy/scroll.magnification)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func mouseUp(with event: NSEvent) { if !dragged { scroll?.toggleZoom(at: convert(event.locationInWindow, from: nil)) } }
}
final class PhotoScroll: NSScrollView {
    let picture = ImageSurface()
    let failureLabel = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    var path = ""
    var pixelSize = NSSize.zero
    var fit = true
    var lastSize = NSSize.zero
    var rawPath: String?
    var focus: FocusPoint?
    var showsFocusBox = false
    private var overlayFallback: FocusPoint?
    private var requestedOverlayPath: String?
    private var overlayToken = UUID()
    var loading = false
    var wantsFocus = false
    var focusTracking = false
    var focusFallbackChecked = false
    var focusToken = UUID()
    private var imageToken = UUID()
    var onMessage: ((String) -> Void)?
    var onFocusTrackingChange: ((Bool) -> Void)?
    var onViewportChange: ((String) -> Void)?
    var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; contentView = CenterClip(); contentView.wantsLayer = true; contentView.drawsBackground = false
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        allowsMagnification = true; minMagnification = 0.01; maxMagnification = 8
        picture.scroll = self; documentView = picture
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false; addSubview(spinner)
        failureLabel.alignment = .center; failureLabel.font = .systemFont(ofSize: 12); failureLabel.textColor = .secondaryLabelColor; failureLabel.isHidden = true; addSubview(failureLabel)
        observers.append(NotificationCenter.default.addObserver(forName: .filterFocusZoom, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.path else { return }; self.focusZoom()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .filterFitImage, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.path else { return }; self.fitImage(); self.onMessage?("已恢复适应窗口")
        })
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func load(_ newPath: String) {
        guard path != newPath else { return }; path = newPath; fit = true; loading = true; focus = nil; focusFallbackChecked = false; wantsFocus = focusTracking; focusToken = UUID()
        resetOverlayFallback()
        let token = UUID(); imageToken = token
        failureLabel.isHidden = true
        if ImageStore.shared.cache.object(forKey: newPath as NSString) == nil { picture.layer?.contents = nil }
        spinner.startAnimation(nil)
        ImageStore.shared.load(newPath) { [weak self] frame in
            guard let self, self.path == newPath,self.imageToken == token else { return }; self.spinner.stopAnimation(nil); self.loading = false; self.focus = frame?.focus
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.picture.layer?.contents = frame?.image
            self.pixelSize = frame.map { NSSize(width: $0.image.width, height: $0.image.height) } ?? NSSize(width: 600, height: 400)
            self.picture.frame = NSRect(origin: .zero, size: self.pixelSize)
            CATransaction.commit()
            let pendingFocus = self.wantsFocus || self.focusTracking
            self.fitImage(resetFocusTracking: false)
            self.resolveOverlayFocus()
            if pendingFocus { self.focusZoom() }
            if frame == nil {
                self.failureLabel.stringValue = MediaDecoder.isRAW(newPath) ? "RAW 无法解码\n系统尚不支持此相机的 RAW 编码，或文件已损坏。" : "图像无法读取\n请检查文件是否在线或已损坏。"
                self.failureLabel.isHidden = false; self.needsLayout = true
                self.picture.setAccessibilityLabel("图像无法读取 · " + URL(fileURLWithPath: newPath).lastPathComponent)
            }
        }
    }
    func setFocusTracking(_ enabled: Bool) {
        guard focusTracking != enabled else { return }
        focusTracking = enabled; onFocusTrackingChange?(enabled)
    }
    func fitImage(resetFocusTracking: Bool = true) {
        if resetFocusTracking { setFocusTracking(false) }
        wantsFocus = false; focusToken = UUID()
        guard pixelSize.width > 0, contentSize.width > 0 else { return }
        fit = true; magnification = max(0.01, min(contentSize.width/pixelSize.width, contentSize.height/pixelSize.height))
        let visible = contentView.bounds.size
        contentView.scroll(to: NSPoint(x: (pixelSize.width-visible.width)/2, y: (pixelSize.height-visible.height)/2))
        reflectScrolledClipView(contentView)
        updateFocusBox()
        picture.setAccessibilityLabel("适应窗口 · " + URL(fileURLWithPath: path).lastPathComponent)
        if resetFocusTracking || !focusTracking { onViewportChange?("适应窗口") }
    }
    func focusZoom() {
        setFocusTracking(true)
        if loading { wantsFocus = true; return }
        let photoPath = path, fallback = rawPath, token = UUID()
        focusToken = token
        // Decoded JPEG coordinates are already available: apply before the next
        // composite so switching photos never flashes a fitted frame first.
        if let focus { applyFocusPoint(focus); return }
        // A missing AF record still gets an immediate 100% view. A paired RAW
        // can subsequently supply the real point; the tracking intent stays on.
        applyFocusPoint(nil)
        guard let fallback, !focusFallbackChecked else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FocusMetadata.read(fallback)
            DispatchQueue.main.async {
                guard let self, self.path == photoPath, self.focusToken == token else { return }
                self.focusFallbackChecked = true
                self.applyFocusPoint(result)
            }
        }
    }
    func applyFocusPoint(_ point: FocusPoint?) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        guard let point, abs(pixelSize.width/pixelSize.height-point.aspect) < 0.025 else {
            zoom100(at: NSPoint(x: pixelSize.width/2,y: pixelSize.height/2), label: "1:1 中心兜底 · " + URL(fileURLWithPath: path).lastPathComponent, mode: "中心 100%")
            onMessage?("未记录可用对焦坐标，已按画面中心放大至 100%"); return
        }
        focus = point
        let target = NSPoint(x: point.x*pixelSize.width, y: (1-point.y)*pixelSize.height)
        zoom100(at: target, label: "1:1 对焦点 · " + URL(fileURLWithPath: path).lastPathComponent, mode: "对焦点 100%")
        onMessage?("已按记录的 Nikon 对焦点放大至 100%" + (point.inFocus == false ? " · 相机记录为未合焦" : ""))
    }
    func resetOverlayFallback() {
        overlayFallback = nil; requestedOverlayPath = nil; overlayToken = UUID()
        updateFocusBox()
    }

    private func compatible(_ point: FocusPoint?) -> FocusPoint? {
        guard let point, pixelSize.height > 0, abs(pixelSize.width/pixelSize.height-point.aspect) < 0.025 else { return nil }
        return point
    }

    func resolveOverlayFocus() {
        updateFocusBox()
        guard showsFocusBox, !loading, compatible(focus) == nil, let rawPath, requestedOverlayPath != rawPath,
              !path.isEmpty, failureLabel.isHidden else { return }
        requestedOverlayPath = rawPath
        let token = overlayToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let point = FocusMetadata.read(rawPath)
            DispatchQueue.main.async {
                guard let self, self.overlayToken == token else { return }
                self.overlayFallback = point
                self.updateFocusBox()
            }
        }
    }

    func updateFocusBox() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard showsFocusBox, !loading, failureLabel.isHidden,
              let point = compatible(focus) ?? compatible(overlayFallback) else {
            picture.focusBox.path = nil; picture.focusOutline.path = nil; return
        }
        let scale = max(0.01, magnification)
        let width = max(16/scale, (point.areaSize?.width ?? 0)*pixelSize.width)
        let height = max(16/scale, (point.areaSize?.height ?? 0)*pixelSize.height)
        let rect = CGRect(x: point.x*pixelSize.width-width/2, y: (1-point.y)*pixelSize.height-height/2, width: width, height: height)
        let box = CGPath(rect: rect, transform: nil)
        picture.focusOutline.frame = picture.bounds; picture.focusBox.frame = picture.bounds
        picture.focusOutline.path = box; picture.focusOutline.lineWidth = 3.4/scale
        picture.focusBox.path = box; picture.focusBox.lineWidth = 1.45/scale
    }
    func zoom100(at point: NSPoint, label: String, mode: String = "100%") {
        fit = false; wantsFocus = false
        setMagnification(1 / (window?.backingScaleFactor ?? 2), centeredAt: point)
        var proposed = contentView.bounds
        proposed.origin = NSPoint(x: point.x-proposed.width/2, y: point.y-proposed.height/2)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
        updateFocusBox()
        picture.setAccessibilityLabel(label)
        onViewportChange?(mode)
    }
    func toggleZoom(at point: NSPoint) {
        if fit {
            focusToken = UUID()
            zoom100(at: point, label: "1:1 原始像素 · 拖动平移 · " + URL(fileURLWithPath: path).lastPathComponent)
            onMessage?("已在点击位置放大至 100%")
        } else { fitImage(); onMessage?("已恢复适应窗口") }
    }
    override func magnify(with event: NSEvent) { focusToken = UUID(); wantsFocus = false; fit = false; super.magnify(with: event); updateFocusBox(); onViewportChange?("\(Int((magnification * (window?.backingScaleFactor ?? 2) * 100).rounded()))%") }
    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: bounds.midX-12, y: bounds.midY-12, width: 24, height: 24)
        failureLabel.frame = NSRect(x: bounds.midX-min(320,bounds.width-24)/2,y: bounds.midY-30,width: min(320,bounds.width-24),height: 60)
        if fit && contentSize != lastSize { lastSize = contentSize; fitImage(resetFocusTracking: false) }
    }
}
struct ImageCanvas: NSViewRepresentable {
    var path: String
    var raw: String? = nil
    var focusTracking: Bool = false
    var showsFocusBox = false
    var onMessage: ((String) -> Void)? = nil
    var onFocusTrackingChange: ((Bool) -> Void)? = nil
    var onViewportChange: ((String) -> Void)? = nil
    func makeNSView(context: Context) -> PhotoScroll { PhotoScroll() }
    func updateNSView(_ view: PhotoScroll, context: Context) {
        let changedMode = view.focusTracking != focusTracking, changedPhoto = view.path != path
        if view.rawPath != raw {
            view.focusFallbackChecked = false
            if !changedPhoto { view.focus = ImageStore.shared.cache.object(forKey: path as NSString)?.focus }
            view.resetOverlayFallback()
        }
        view.rawPath = raw; view.onMessage = onMessage; view.onFocusTrackingChange = onFocusTrackingChange; view.onViewportChange = onViewportChange; view.focusTracking = focusTracking
        view.showsFocusBox = showsFocusBox
        view.load(path)
        view.resolveOverlayFocus()
        if changedMode && !changedPhoto { if focusTracking { view.focusZoom() } else { view.fitImage() } }
    }
}

struct ExifRows: View {
    var path: String
    var companion: String?
    @State private var rows: [(String, String)] = []
    @State private var histogram: PhotoHistogram?
    var body: some View {
        Group {
            HistogramPlot(histogram: histogram,loading: rows.isEmpty,raw: MediaDecoder.isRAW(path)).padding(.bottom,4)
            Divider()
            Text("拍摄信息").font(.system(size: 11,weight: .semibold)).padding(.top,4)
            if rows.isEmpty { ProgressView().controlSize(.small) }
            ForEach(rows, id: \.0) { key, value in HStack(alignment: .top) { Text(key).foregroundStyle(.secondary).frame(width: 55, alignment: .leading); Text(value).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled) }.font(.system(size: 11)) }
        }.task(id: [path,companion ?? ""]) {
            rows = []; histogram = nil
            let frame: ImageFrame? = await withCheckedContinuation { continuation in ImageStore.shared.load(path) { continuation.resume(returning: $0) } }
            guard !Task.isCancelled else { return }
            guard let frame else { rows = [("图像", "无法读取 EXIF")]; return }
            var focus = frame.recordedFocus
            histogram = frame.histogram; rows = frame.rows + (frame.pictureControl?.rows ?? []) + focus.rows
            let canUseFocusFallback = !MediaDecoder.isRAW(path)
            if let companion, frame.pictureControl == nil || (canUseFocusFallback && (focus.distance == nil || focus.point == nil)) {
                let (fallback, pictureControl) = await Task.detached(priority: .utility) { FocusMetadata.recorded(companion) }.value
                guard !Task.isCancelled else { return }
                if canUseFocusFallback {
                    focus.distance = focus.distance ?? fallback.distance
                    let aspect = Double(frame.image.width)/Double(frame.image.height)
                    if focus.point == nil, let point = fallback.point, abs(point.aspect-aspect) < 0.025 { focus.point = point }
                    focus.mode = focus.mode ?? fallback.mode
                    focus.areaMode = focus.areaMode ?? fallback.areaMode
                    focus.inFocus = focus.inFocus ?? fallback.inFocus
                }
                rows = frame.rows + ((frame.pictureControl ?? pictureControl)?.rows ?? []) + focus.rows
            }
        }
    }
}
