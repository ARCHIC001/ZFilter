import SwiftUI
import AppKit
import QuartzCore

enum FilterAppearance: String {
    case system, light, dark

    var native: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum FilterPalette: CaseIterable {
    case orange, green, cyan, yellow, red, pink, blue, purple, gray
    var hex: [UInt32] {
        switch self {
        case .orange: return [0xff6d0a,0xff8a3b,0xff844a]
        case .green: return [0x1dcd3a,0x117b23,0x829f23]
        case .cyan: return [0x6be6b3,0x50b996,0x335077]
        case .yellow: return [0xffbb10,0xffcf58,0xc09a3b]
        case .red: return [0xfa382e,0xaf2720,0xec6563]
        case .pink: return [0xf5b1bc,0xe6c3d4,0xd58c97]
        case .blue: return [0x3482ff,0x71a8ff,0x5d8bb8]
        case .purple: return [0x6a5ddf,0x5348ae,0x50406b]
        case .gray: return [0x929292,0x505050,0xb6bfcd]
        }
    }
    static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex>>16)&255)/255,green: CGFloat((hex>>8)&255)/255,blue: CGFloat(hex&255)/255,alpha: alpha)
    }
    var color: Color { Color(nsColor: Self.ns(hex[0])) }
    var soft: Color { Color(nsColor: Self.ns(hex[1])) }
    func accent(dark: Bool) -> NSColor { Self.ns(hex[dark ? 1 : 0]) }
    static func luminance(_ hex: UInt32) -> Double {
        let rgb = [hex>>16,(hex>>8)&255,hex&255].map { value -> Double in
            let x = Double(value)/255; return x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4)
        }
        return rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722
    }
    func inkHex(dark: Bool) -> UInt32 {
        if self == .blue { return dark ? hex[1] : FilterPalette.cyan.hex[2] }
        let background = Self.luminance(dark ? 0x151518 : 0xffffff)
        return hex.first { code in
            let foreground = Self.luminance(code)
            return (max(foreground,background)+0.05)/(min(foreground,background)+0.05)>=4.5
        } ?? FilterPalette.gray.hex[dark ? 2 : 1]
    }
    func ink(dark: Bool) -> Color { Color(nsColor: Self.ns(inkHex(dark: dark))) }
}

enum ProjectConnection: String {
    case checking, online, offline
    var label: String { self == .online ? "在线" : self == .offline ? "离线" : "检查中" }
    var detail: String { self == .online ? "项目目录可访问" : self == .offline ? "磁盘未连接或项目目录不可访问" : "正在检查项目目录" }
}

struct ViewerToolStyle: ButtonStyle {
    var active = false
    var width: CGFloat? = 30
    func makeBody(configuration: Configuration) -> some View {
        ViewerToolFace(label: configuration.label, active: active, pressed: configuration.isPressed, width: width)
    }
}
private struct ViewerToolFace<Label: View>: View {
    let label: Label
    let active: Bool
    let pressed: Bool
    let width: CGFloat?
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        label.font(.system(size: 14,weight: .medium)).symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary).frame(width: width,height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(pressed ? 0.17 : active ? 0.11 : hovered ? 0.065 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(active ? 0.13 : 0),lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6)).opacity(enabled ? 1 : 0.35)
            .scaleEffect(pressed && !reduced ? (width == nil ? 0.98 : 0.94) : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: reduced ? 0 : 0.12),value: hovered)
            .animation(.easeOut(duration: reduced ? 0 : 0.12),value: pressed)
    }
}

struct ConnectionIndicator: NSViewRepresentable {
    let state: ProjectConnection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> ConnectionLight { ConnectionLight(frame: NSRect(x: 0,y: 0,width: 14,height: 14)) }
    func updateNSView(_ view: ConnectionLight, context: Context) { view.update(state, reduced: reduceMotion) }
}

final class ConnectionLight: NSView {
    let core = CAShapeLayer(), halo = CAShapeLayer()
    var state = ProjectConnection.checking
    var reduced = false
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        halo.path = CGPath(ellipseIn: CGRect(x: 1.5,y: 1.5,width: 11,height: 11),transform: nil); halo.frame = bounds; halo.fillColor = nil; halo.lineWidth = 1
        core.path = CGPath(ellipseIn: CGRect(x: 3.5,y: 3.5,width: 7,height: 7),transform: nil); core.frame = bounds; core.lineWidth = 0.5
        layer!.addSublayer(halo); layer!.addSublayer(core)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        update(.checking,reduced: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animateIfNeeded() }
    func update(_ next: ProjectConnection, reduced: Bool) {
        state = next; self.reduced = reduced
        let hue: FilterPalette = state == .online ? .green : .yellow
        CATransaction.begin(); CATransaction.setDisableActions(true)
        core.fillColor = FilterPalette.ns(hue.hex[0],alpha: state == .checking ? 0.55 : 1).cgColor
        core.strokeColor = FilterPalette.ns(FilterPalette.gray.hex[1],alpha: 0.4).cgColor
        halo.strokeColor = FilterPalette.ns(hue.hex[0],alpha: 0.55).cgColor; halo.opacity = state == .online ? 0.24 : 0.12
        CATransaction.commit()
        setAccessibilityLabel("项目"+state.label); toolTip = state.label+" · "+state.detail
        animateIfNeeded()
    }
    func animateIfNeeded() {
        guard state == .online, !reduced, window != nil else { halo.removeAnimation(forKey: "breathe"); return }
        guard halo.animation(forKey: "breathe") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 0.16; pulse.toValue = 0.44
        pulse.duration = 2.4; pulse.autoreverses = true; pulse.repeatCount = .infinity; pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(pulse,forKey: "breathe")
    }
}
