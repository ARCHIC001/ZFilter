import SwiftUI
import AppKit
import ImageIO
import QuartzCore

final class ThumbnailFrame {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    let cache = NSCache<NSString, ThumbnailFrame>()
    let queue = OperationQueue()
    private let lock = NSLock()
    private var waiting: [String: [(CGImage?) -> Void]] = [:]
    init() { cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 160; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility }
    func cached(_ path: String) -> CGImage? { cache.object(forKey: path as NSString)?.image }
    func load(_ path: String, prefetch: Bool = false, completion: @escaping (CGImage?) -> Void = { _ in }) {
        if let image = cached(path) { DispatchQueue.main.async { completion(image) }; return }
        lock.lock()
        if waiting[path] != nil { waiting[path]!.append(completion); lock.unlock(); return }
        waiting[path] = [completion]; lock.unlock()
        let operation = BlockOperation {
            let image: CGImage? = autoreleasepool {
                MediaDecoder.decode(path,maxPixelSize: 320)?.image
            }
            if let image { self.cache.setObject(ThumbnailFrame(image), forKey: path as NSString, cost: image.bytesPerRow * image.height) }
            self.lock.lock(); let callbacks = self.waiting.removeValue(forKey: path) ?? []; self.lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }
        operation.queuePriority = prefetch ? .low : .veryHigh; queue.addOperation(operation)
    }
}

struct FilmstripEntry: Identifiable {
    let photo: Photo
    let index: Int
    var raw = false
    var burstCount = 0
    var burstFrame: Int?
    var burstBadge: String? {
        guard burstCount > 1 else { return nil }
        return burstFrame.map { "\($0)/\(burstCount)" } ?? "×\(burstCount)"
    }
    var id: String { raw ? photo.raw ?? "" : photo.jpeg }
}
func filmstripEntries(_ photos: [Photo], index: Int,raw: Bool = false) -> [FilmstripEntry] {
    guard photos.indices.contains(index) else { return [] }
    // One extra offscreen tile on each side enters smoothly as the seven visible slots move.
    return (max(0, index-4)...min(photos.count-1, index+4)).map { FilmstripEntry(photo: photos[$0], index: $0,raw: raw) }
}
struct FilmstripDeparture: Identifiable {
    enum Kind { case pool, trash }
    let id = UUID()
    let path: String
    let image: CGImage?
    let kind: Kind
}

struct FilmstripBar: View {
    @EnvironmentObject var m: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var selectionHue: FilterPalette { m.deleteMode == "仅 JPEG" ? .green : m.deleteMode == "仅 RAW" ? .yellow : .red }
    var body: some View {
        let photos = m.photos
        let groups = m.burstGroups
        let entries = filmstripEntries(photos, index: m.index,raw: m.viewingRAW).map { entry in
            var tile = entry
            if let id = m.burstIDs[tile.id], let members = groups[id] {
                tile.burstCount = members.count
                if !m.isBurstCollapsed(id), let offset = members.firstIndex(of: tile.id) { tile.burstFrame = offset+1 }
            }
            return tile
        }
        VStack(spacing: 0) {
            FilmstripTrack(entries: entries, index: m.index, count: photos.count, departures: m.filmstripDepartures, reduceMotion: reduceMotion, dark: scheme == .dark, selectionHue: selectionHue, onSelect: m.selectPhoto, onNavigate: m.selectIndex, onToggleBurst: m.toggleBurst)
                .frame(height: 102)
            if photos.count > 1 {
                FilmstripScrubber(photos: photos, index: m.index, raw: m.viewingRAW, hue: selectionHue, onSelect: m.selectIndex)
                    .padding(.horizontal, 16).padding(.bottom, 6).disabled(m.busy)
                    .id("\(m.root)|\(m.showPool)|\(m.deleteMode)|\(photos.count)")
            }
        }
            .background {
                RoundedRectangle(cornerRadius: 12).fill(selectionHue.color.opacity(0.045)).modifier(FloatingGlass(radius: 12))
                    .shadow(color: selectionHue.color.opacity(scheme == .dark ? 0.22 : 0.12),radius: 10,y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LinearGradient(colors: [.white.opacity(0.4),selectionHue.color.opacity(0.32),selectionHue.soft.opacity(0.12)],startPoint: .topLeading,endPoint: .bottomTrailing),lineWidth: 0.7).allowsHitTesting(false))
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18),value: m.deleteMode)
            .accessibilityElement(children: .contain).accessibilityLabel("照片预览条，前后三张，可左右拖动导航").accessibilityValue("当前查看及删除范围："+m.deleteMode)
            .help("左右拖动或横向滚动快速浏览，点击缩略图跳转，点击角标展开或折叠本组连拍")
    }
}

struct FilmstripScrubber: View {
    let photos: [Photo]
    let index: Int
    let raw: Bool
    let hue: FilterPalette
    let onSelect: (Int) -> Void
    @GestureState private var draft: Int?

    static func target(x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard width > 0, count > 1 else { return 0 }
        let fraction = min(1, max(0, x/width))
        return Int((fraction * CGFloat(count-1)).rounded())
    }

    var body: some View {
        let position = min(draft ?? index, photos.count-1)
        let photo = photos[position]
        let name = URL(fileURLWithPath: raw ? photo.raw ?? "" : photo.jpeg).lastPathComponent
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width-12)
                let offset = width * CGFloat(position) / CGFloat(photos.count-1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    Capsule().fill(hue.color.opacity(0.62)).frame(width: offset+6, height: 4)
                    Circle().fill(hue.color).overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                        .frame(width: 12,height: 12).offset(x: offset)
                }.frame(maxHeight: .infinity).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($draft) { value, state, _ in state = Self.target(x: value.location.x-6, width: width, count: photos.count) }
                        .onEnded { value in onSelect(Self.target(x: value.location.x-6, width: width, count: photos.count)) })
            }.frame(height: 18)
            HStack {
                Text(draft == nil ? "快速定位" : name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(position+1) / \(photos.count)").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.help("点击或拖动定位整个照片池，松手跳到目标照片")
            .accessibilityElement(children: .ignore).accessibilityLabel("预览条快速定位")
            .accessibilityValue("第 \(position+1) 张，共 \(photos.count) 张")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { onSelect(min(index+1,photos.count-1)) }
                if direction == .decrement { onSelect(max(index-1,0)) }
            }
    }
}

struct FilmstripTrack: NSViewRepresentable {
    let entries: [FilmstripEntry]
    let index: Int
    let count: Int
    let departures: [FilmstripDeparture]
    let reduceMotion: Bool
    let dark: Bool
    let selectionHue: FilterPalette
    let onSelect: (String) -> Void
    let onNavigate: (Int) -> Void
    let onToggleBurst: (String) -> Bool
    func makeNSView(context: Context) -> FilmstripTrackView { FilmstripTrackView() }
    func updateNSView(_ view: FilmstripTrackView, context: Context) {
        view.onSelect = onSelect; view.onNavigate = onNavigate; view.photoCount = count; view.reduceMotion = reduceMotion; view.selectionHue = selectionHue
        view.onToggleBurst = onToggleBurst
        view.update(entries, index: index, departures: departures, dark: dark)
    }
}

final class FilmstripTile: NSView {
    let path: String
    let imageLayer = CALayer(), numberLayer = CATextLayer()
    let burstBadgeLayer = CATextLayer()
    let glowLayer = CALayer(), glassRim = CAGradientLayer(), rimMask = CAShapeLayer()
    var onSelect: ((String) -> Void)?
    weak var track: FilmstripTrackView?
    private var displayIndex = -1
    private var burstCount = 0
    private var burstFrame: Int?
    private var pressedBadge = false
    private var current = false, dark = false, hovered = false
    private var selectionHue = FilterPalette.red
    private var pointerTracking: NSTrackingArea?
    var reduceMotion = false
    override var isFlipped: Bool { true }
    init(path: String) {
        self.path = path; super.init(frame: .zero); wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill; imageLayer.cornerRadius = 8; imageLayer.masksToBounds = true
        numberLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium); numberLayer.fontSize = 10; numberLayer.alignmentMode = .center
        burstBadgeLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        burstBadgeLayer.fontSize = 9; burstBadgeLayer.alignmentMode = .center
        burstBadgeLayer.cornerRadius = 4; burstBadgeLayer.foregroundColor = NSColor.white.cgColor
        burstBadgeLayer.isHidden = true; imageLayer.addSublayer(burstBadgeLayer)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOffset = CGSize(width: 0,height: 2)
        glowLayer.cornerRadius = 8; glowLayer.shadowOffset = CGSize(width: 0,height: 1); glowLayer.shadowRadius = 12
        glassRim.startPoint = CGPoint(x: 0,y: 0); glassRim.endPoint = CGPoint(x: 1,y: 1)
        rimMask.fillColor = nil; rimMask.strokeColor = NSColor.white.cgColor; rimMask.lineWidth = 0.6; glassRim.mask = rimMask
        layer!.addSublayer(glowLayer); layer!.addSublayer(imageLayer); layer!.addSublayer(glassRim); layer!.addSublayer(numberLayer)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        if let image = ThumbnailStore.shared.cached(path) { imageLayer.contents = image }
        else { ThumbnailStore.shared.load(path) { [weak self] image in
            guard let self else { return }; CATransaction.begin(); CATransaction.setDisableActions(true); self.imageLayer.contents = image; CATransaction.commit()
        } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var badgeHitRect: CGRect {
        burstBadgeLayer.isHidden ? .zero : burstBadgeLayer.frame.insetBy(dx: -2,dy: -2).intersection(bounds)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !badgeHitRect.isEmpty { addCursorRect(badgeHitRect,cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) {
        pressedBadge = badgeHitRect.contains(convert(event.locationInWindow,from: nil))
        track?.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) { track?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) {
        let moved = track?.dragged ?? false
        track?.mouseUp(with: event)
        let point = convert(event.locationInWindow,from: nil)
        defer { pressedBadge = false }
        guard !moved, bounds.contains(point) else { return }
        if pressedBadge {
            if badgeHitRect.contains(point) { _ = track?.onToggleBurst?(path) }
        } else { onSelect?(path) }
    }
    override func scrollWheel(with event: NSEvent) { track?.scrollWheel(with: event) }
    override func accessibilityPerformPress() -> Bool { onSelect?(path); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; emphasize(animated: !reduceMotion) }
    override func mouseExited(with event: NSEvent) { hovered = false; emphasize(animated: !reduceMotion) }
    func decorate(_ entry: FilmstripEntry, current: Bool, dark: Bool, selectionHue: FilterPalette = .red) {
        guard displayIndex != entry.index || self.current != current || self.dark != dark || self.selectionHue != selectionHue || burstCount != entry.burstCount || burstFrame != entry.burstFrame else { updateGlowAnimation(); return }
        let fadeColor = self.current && current && self.selectionHue != selectionHue && !reduceMotion
        displayIndex = entry.index; self.current = current; self.dark = dark; self.selectionHue = selectionHue
        burstCount = entry.burstCount; burstFrame = entry.burstFrame
        let ink = FilterPalette.ns(selectionHue.inkHex(dark: dark))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.backgroundColor = FilterPalette.ns(FilterPalette.gray.hex[0],alpha: 0.15).cgColor
        numberLayer.string = String(entry.index+1)
        numberLayer.foregroundColor = (current ? ink : FilterPalette.ns(FilterPalette.gray.hex[dark ? 2 : 1])).cgColor
        numberLayer.contentsScale = window?.backingScaleFactor ?? 2
        burstBadgeLayer.contentsScale = numberLayer.contentsScale
        burstBadgeLayer.string = entry.burstBadge
        burstBadgeLayer.isHidden = entry.burstBadge == nil
        burstBadgeLayer.backgroundColor = (burstFrame == nil ? FilterPalette.ns(0x3a4961, alpha: 0.94) : NSColor.black.withAlphaComponent(0.78)).cgColor
        layoutBurstBadge()
        CATransaction.commit()
        emphasize(animated: false,fadeColor: fadeColor)
        window?.invalidateCursorRects(for: self)
        let mode = selectionHue == .green ? "仅 JPEG" : selectionHue == .yellow ? "仅 RAW" : "JPEG + RAW"
        let name = URL(fileURLWithPath: entry.id).lastPathComponent
        let burst = burstCount > 1 ? (burstFrame.map { " · 连拍第 \($0) 张，共 \(burstCount) 张" } ?? " · 已折叠，连拍 \(burstCount) 张") : ""
        let action = burstFrame == nil ? "展开本组连拍" : "折叠本组连拍"
        toolTip = name+burst+(burstCount > 1 ? " · 点击角标\(action)" : "")
        setAccessibilityLabel("预览第 \(entry.index+1) 张 \(name)"+burst); setAccessibilityValue(current ? "当前照片 · "+mode : "")
        setAccessibilityCustomActions(burstCount > 1 ? [NSAccessibilityCustomAction(name: action) { [weak self] in
            guard let self else { return false }
            return track?.onToggleBurst?(path) ?? false
        }] : [])
    }
    private func layoutBurstBadge() {
        let length = (burstBadgeLayer.string as? String)?.count ?? 0
        let width = min(max(0, imageLayer.bounds.width-6), max(22, CGFloat(length)*5.7+10))
        burstBadgeLayer.frame = CGRect(x: imageLayer.bounds.width-width-3, y: 3, width: width, height: 17)
        burstBadgeLayer.isWrapped = false
        burstBadgeLayer.truncationMode = .end
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGlowAnimation() }
    private func updateGlowAnimation() {
        guard current,!reduceMotion,window != nil else { glowLayer.removeAnimation(forKey: "breathe"); return }
        guard glowLayer.animation(forKey: "breathe") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 0.78; pulse.toValue = 1
        pulse.duration = 2.8; pulse.autoreverses = true; pulse.repeatCount = .infinity; pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse,forKey: "breathe")
    }
    private func emphasize(animated: Bool,fadeColor: Bool = false) {
        let accent = FilterPalette.ns(selectionHue.hex[0])
        let old = imageLayer.presentation()?.transform ?? imageLayer.transform
        let scale: CGFloat = hovered ? 1.02 : 1
        CATransaction.begin(); CATransaction.setDisableActions(!fadeColor); CATransaction.setAnimationDuration(0.18)
        for surface in [imageLayer,glowLayer,glassRim] { surface.transform = CATransform3DMakeScale(scale,scale,1) }
        layer?.opacity = current || hovered ? 1 : 0.8; layer?.shadowOpacity = hovered ? 0.16 : current ? 0.1 : 0.04; layer?.shadowRadius = hovered ? 7 : 4
        // One fine reflection follows the image contour; color lives in the
        // diffuse shadow instead of two saturated concentric borders.
        imageLayer.borderWidth = current ? 0 : 0.5
        imageLayer.borderColor = NSColor.white.withAlphaComponent(hovered ? 0.4 : 0.2).cgColor
        glowLayer.backgroundColor = accent.withAlphaComponent(0.025).cgColor; glowLayer.shadowColor = accent.cgColor
        glowLayer.shadowOpacity = dark ? 0.46 : 0.34; glowLayer.opacity = current ? 1 : 0
        glassRim.colors = [NSColor.white.withAlphaComponent(dark ? 0.65 : 0.85).cgColor,NSColor.white.withAlphaComponent(0.08).cgColor,accent.withAlphaComponent(0.12).cgColor,NSColor.white.withAlphaComponent(0.22).cgColor]
        glassRim.locations = [0,0.36,0.72,1]; glassRim.opacity = current ? 1 : 0
        CATransaction.commit()
        updateGlowAnimation()
        if animated {
            let lift = CABasicAnimation(keyPath: "transform"); lift.fromValue = NSValue(caTransform3D: old); lift.toValue = NSValue(caTransform3D: imageLayer.transform)
            lift.duration = 0.12; lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for surface in [imageLayer,glowLayer,glassRim] { surface.add(lift,forKey: "hover") }
        }
    }
    func place(_ rect: CGRect, animated: Bool) {
        guard frame != rect else { return }
        let previous = layer?.presentation()?.position ?? layer?.position ?? .zero, hadFrame = frame.width > 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = rect
        let imageRect = CGRect(x: 0,y: 0,width: rect.width,height: rect.height-18)
        // Bounds/position remain exact while hovered; assigning frame with a
        // nonidentity transform would distort the rounded corners on resize.
        for surface in [imageLayer,glowLayer,glassRim] { surface.bounds = CGRect(origin: .zero,size: imageRect.size); surface.position = CGPoint(x: imageRect.midX,y: imageRect.midY) }
        layoutBurstBadge()
        rimMask.frame = glassRim.bounds
        rimMask.path = CGPath(roundedRect: glassRim.bounds.insetBy(dx: 0.3,dy: 0.3),cornerWidth: 7.7,cornerHeight: 7.7,transform: nil)
        glowLayer.shadowPath = CGPath(roundedRect: glowLayer.bounds,cornerWidth: 8,cornerHeight: 8,transform: nil)
        numberLayer.frame = CGRect(x: 0, y: rect.height-12, width: rect.width, height: 12)
        layer?.shadowPath = CGPath(roundedRect: imageRect,cornerWidth: 8,cornerHeight: 8,transform: nil)
        CATransaction.commit()
        if animated && hadFrame, let layer {
            let slide = CABasicAnimation(keyPath: "position"); slide.fromValue = NSValue(point: previous); slide.toValue = NSValue(point: layer.position)
            slide.duration = 0.20; slide.timingFunction = CAMediaTimingFunction(name: .easeOut); layer.add(slide, forKey: "slide")
        } else { layer?.removeAnimation(forKey: "slide") }
    }
}

final class FilmstripTrackView: NSView {
    let viewport = NSView()
    var tiles: [String: FilmstripTile] = [:]
    var effectLayers: [UUID: CALayer] = [:]
    var entries: [FilmstripEntry] = []
    var index = 0
    var lastSize = CGSize.zero
    var reduceMotion = false
    var selectionHue = FilterPalette.red
    var onSelect: ((String) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onToggleBurst: ((String) -> Bool)?
    var photoCount = 0
    var dragged = false
    private var navigating = false
    private var anchorIndex = 0, requestedIndex = 0
    private var startX: CGFloat = 0, translation: CGFloat = 0
    private var scrollEnd: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false
        viewport.wantsLayer = true; viewport.layer?.masksToBounds = true; addSubview(viewport)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .openHand) }
    func beginNavigation() {
        scrollEnd?.cancel(); navigating = true; dragged = false
        anchorIndex = index; requestedIndex = index; translation = 0
    }
    func navigate(translation: CGFloat) {
        guard navigating,photoCount>0 else { return }
        self.translation = translation
        if abs(translation)>5 { dragged = true }
        guard dragged else { return }
        let target = min(photoCount-1,max(0,anchorIndex-Int((translation/(tileSize.width+9)).rounded())))
        // Clamp the residual at either edge instead of dragging the strip away.
        self.translation = min(CGFloat(anchorIndex)*(tileSize.width+9)+24,max(-CGFloat(photoCount-1-anchorIndex)*(tileSize.width+9)-24,translation))
        if target != requestedIndex { requestedIndex = target; onNavigate?(target) }
        arrange(animated: false)
    }
    func endNavigation() { navigating = false; translation = 0; arrange(animated: !reduceMotion) }
    override func mouseDown(with event: NSEvent) { beginNavigation(); startX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { navigate(translation: event.locationInWindow.x-startX) }
    override func mouseUp(with event: NSEvent) { endNavigation() }
    override func scrollWheel(with event: NSEvent) {
        if !navigating { beginNavigation() }
        let delta = abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        navigate(translation: translation+delta*(event.hasPreciseScrollingDeltas ? 1 : 18))
        scrollEnd?.cancel()
        let finish = DispatchWorkItem { [weak self] in self?.endNavigation() }
        scrollEnd = finish; DispatchQueue.main.asyncAfter(deadline: .now()+0.14,execute: finish)
    }
    var tileSize: CGSize { let w = max(24, (bounds.width-32-6*9)/7); return CGSize(width: w, height: w*2/3) }
    func update(_ next: [FilmstripEntry], index: Int, departures: [FilmstripDeparture], dark: Bool) {
        let animate = !entries.isEmpty && (self.index != index || entries.map(\.id) != next.map(\.id))
        self.entries = next; self.index = index
        let ids = Set(next.map(\.id))
        for key in Array(tiles.keys) where !ids.contains(key) { tiles.removeValue(forKey: key)?.removeFromSuperview() }
        for entry in next {
            let tile = tiles[entry.id] ?? FilmstripTile(path: entry.id)
            if tiles[entry.id] == nil { tiles[entry.id] = tile; viewport.addSubview(tile) }
            tile.track = self; tile.onSelect = { [weak self] path in self?.onSelect?(path) }; tile.reduceMotion = reduceMotion; tile.decorate(entry, current: entry.index == index, dark: dark, selectionHue: selectionHue)
            tile.setAccessibilityHidden(abs(entry.index-index)>3)
        }
        arrange(animated: animate && !reduceMotion && !navigating)
        let activeEffects = Set(departures.map(\.id))
        for id in Array(effectLayers.keys) where !activeEffects.contains(id) { effectLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        for event in departures where effectLayers[event.id] == nil { animateDeparture(event) }
    }
    override func layout() { super.layout(); if lastSize != bounds.size { arrange(animated: false) } }
    func arrange(animated: Bool) {
        lastSize = bounds.size; viewport.frame = CGRect(x: 12, y: 0, width: max(0,bounds.width-24), height: bounds.height)
        let size = tileSize
        for entry in entries {
            let offset = navigating && dragged ? translation+CGFloat(index-anchorIndex)*(size.width+9) : 0
            let rect = CGRect(x: viewport.bounds.midX+CGFloat(entry.index-index)*(size.width+9)-size.width/2+offset, y: (bounds.height-size.height-18)/2, width: size.width, height: size.height+18)
            tiles[entry.id]?.place(rect, animated: animated)
        }
    }
    func animateDeparture(_ event: FilmstripDeparture) {
        let root = CALayer(); root.frame = bounds; root.isGeometryFlipped = true; layer?.addSublayer(root); effectLayers[event.id] = root
        let size = tileSize, center = CGPoint(x: bounds.midX, y: bounds.midY-9)
        let duration = reduceMotion ? 0.12 : event.kind == .pool ? 0.28 : 0.44
        let fragments = event.kind == .trash && !reduceMotion ? filmstripShards(size) : [FilmstripShard(rect: CGRect(origin: .zero, size: size), origin: .zero, drift: .zero, rotation: 0)]
        for fragment in fragments {
            let piece = CALayer(); piece.bounds = CGRect(origin: .zero, size: fragment.rect.size)
            if let image = event.image {
                let scale = max(size.width/CGFloat(image.width),size.height/CGFloat(image.height))
                let rect = CGRect(x: (CGFloat(image.width)-size.width/scale)/2+fragment.rect.minX/scale, y: (CGFloat(image.height)-size.height/scale)/2+fragment.rect.minY/scale, width: fragment.rect.width/scale, height: fragment.rect.height/scale)
                piece.contents = image.cropping(to: rect.integral)
            } else { piece.backgroundColor = NSColor.secondaryLabelColor.cgColor }
            let start = CGPoint(x: center.x+fragment.origin.x, y: center.y+fragment.origin.y)
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = (0...10).map { step -> NSValue in
                let p = Double(step)/10
                let point = event.kind == .pool && !reduceMotion ? CGPoint(x: center.x,y: center.y-150*p) : reduceMotion ? center : CGPoint(x: center.x+fragment.position(p).x,y: center.y+fragment.position(p).y)
                return NSValue(point: point)
            }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            let transform = CABasicAnimation(keyPath: "transform"); transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            let angle = reduceMotion ? 0 : event.kind == .pool ? -9.0 : fragment.rotation
            let shrink = reduceMotion ? 1.0 : event.kind == .pool ? 0.75 : 0.2
            transform.toValue = NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeRotation(angle * .pi/180,0,0,1),shrink,shrink,1))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            piece.position = start; piece.opacity = 0; piece.cornerRadius = event.kind == .pool ? 7 : 0; piece.masksToBounds = true; root.addSublayer(piece)
            CATransaction.commit()
            position.duration = duration; fade.duration = duration; transform.duration = duration
            let group = CAAnimationGroup(); group.animations = [position,fade,transform]; group.duration = duration; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            piece.add(group,forKey: "departure")
        }
    }
}

struct FilmstripShard {
    let rect: CGRect
    let origin: CGPoint
    let drift: CGVector
    let rotation: Double
    func position(_ p: Double) -> CGPoint { CGPoint(x: origin.x+drift.dx*p,y: origin.y+drift.dy*p+55*p*p) }
}
func filmstripShards(_ size: CGSize) -> [FilmstripShard] {
    (0..<70).map { index in
        let column = index%10, row = index/10, seed = Double(index)*2.399963
        let rect = CGRect(x: CGFloat(column)*size.width/10,y: CGFloat(row)*size.height/7,width: size.width/10,height: size.height/7)
        let origin = CGPoint(x: rect.midX-size.width/2,y: rect.midY-size.height/2)
        return FilmstripShard(rect: rect,origin: origin,drift: CGVector(dx: origin.x*1.7+cos(seed)*42,dy: origin.y*1.7+sin(seed)*48),rotation: sin(seed)*150)
    }
}

// Static pixel previews share the native compositor's shard geometry.
struct FilmstripDepartureDrawing: View, Animatable {
    let image: CGImage?
    let kind: FilmstripDeparture.Kind
    let tileSize: CGSize
    var progress: Double
    var reduceMotion = false
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, progress)), w = tileSize.width, h = tileSize.height
            let center = CGPoint(x: size.width/2, y: size.height/2)
            let resolved = image.map { context.resolve(Image(decorative: $0, scale: 1)) }
            let scale = image.map { max(w/CGFloat($0.width), h/CGFloat($0.height)) } ?? 1
            let sourceSize = image.map { CGSize(width: CGFloat($0.width)*scale, height: CGFloat($0.height)*scale) } ?? tileSize
            func drawTile(_ drawing: inout GraphicsContext, at point: CGPoint) {
                if let resolved { drawing.draw(resolved, in: CGRect(x: point.x-sourceSize.width/2, y: point.y-sourceSize.height/2, width: sourceSize.width, height: sourceSize.height)) }
                else { drawing.fill(Path(CGRect(x: point.x-w/2, y: point.y-h/2, width: w, height: h)), with: .color(.secondary)) }
            }
            if kind == .pool || reduceMotion {
                context.opacity = 1-p
                context.translateBy(x: center.x, y: center.y-(reduceMotion ? 0 : 150*p))
                context.rotate(by: .degrees(reduceMotion ? 0 : -9*p)); context.scaleBy(x: 1-0.25*p, y: 1-0.25*p)
                context.clip(to: Path(roundedRect: CGRect(x: -w/2, y: -h/2, width: w, height: h), cornerRadius: 7))
                drawTile(&context, at: .zero)
            } else {
                for fragment in filmstripShards(tileSize) {
                        let point = fragment.position(p)
                        var shard = context
                        shard.opacity = pow(1-p, 1.5)
                        shard.translateBy(x: center.x+point.x, y: center.y+point.y)
                        shard.rotate(by: .degrees(fragment.rotation*p)); shard.scaleBy(x: 1-0.8*p, y: 1-0.8*p)
                        shard.clip(to: Path(CGRect(x: -fragment.rect.width/2, y: -fragment.rect.height/2, width: fragment.rect.width, height: fragment.rect.height)))
                        drawTile(&shard, at: CGPoint(x: -fragment.origin.x, y: -fragment.origin.y))
                }
            }
        }.accessibilityHidden(true)
    }
}
