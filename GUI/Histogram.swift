import SwiftUI
import AppKit

struct PhotoHistogram {
    // RGB and Rec.709 luma of the displayed JPEG, converted to sRGB. Sampling
    // is bounded so opening the inspector never walks a full 45 MP frame.
    let channels: [[Int]]
    let sampleCount: Int
    init?(image: CGImage) {
        let scale = min(1,512 / Double(max(image.width,image.height)))
        let width = max(1,Int(Double(image.width)*scale)), height = max(1,Int(Double(image.height)*scale))
        var bytes = [UInt8](repeating: 0,count: width*height*4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: space,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
            context.interpolationQuality = .medium
            context.draw(image,in: CGRect(x: 0,y: 0,width: width,height: height)); return true
        }
        guard drawn else { return nil }
        var bins = Array(repeating: Array(repeating: 0,count: 256),count: 4)
        for i in stride(from: 0,to: bytes.count,by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
            bins[0][r] += 1; bins[1][g] += 1; bins[2][b] += 1
            bins[3][(r*2126+g*7152+b*722+5000)/10000] += 1
        }
        channels = bins; sampleCount = width*height
    }
    var curves: [[Double]] { curves(logarithmic: false) }
    func curves(logarithmic: Bool) -> [[Double]] {
        let smooth: [[Double]] = channels.map { bins in
            (0..<256).map { i -> Double in
                let count = bins[max(0,i-1)] + 2*bins[i] + bins[min(255,i+1)]
                return Double(count)/4
            }
        }
        let scaled = logarithmic ? smooth.map { $0.map { log1p($0) } } : smooth
        let peak = scaled.flatMap { $0 }.max() ?? 1
        return scaled.map { $0.map { $0/max(1,peak) } }
    }
}

struct HistogramPlot: View {
    let histogram: PhotoHistogram?
    var loading = false
    var raw = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("histogramLogScale") private var logarithmic = true
    var body: some View {
        let dark = colorScheme == .dark
        let colors = [FilterPalette.red.ink(dark: dark), FilterPalette.green.ink(dark: dark),
                      Color(nsColor: FilterPalette.ns(dark ? 0x71a8ff : 0x245caf)), Color.primary]
        let plotShape = RoundedRectangle(cornerRadius: 6)
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Text("直方图").font(.system(size: 11,weight: .semibold)); Spacer()
                Button(logarithmic ? "对数" : "线性") { logarithmic.toggle() }.font(.system(size: 9,weight: .medium)).buttonStyle(.plain).padding(.horizontal,5).padding(.vertical,3).background(Color.primary.opacity(0.06),in: RoundedRectangle(cornerRadius: 4)).help("切换纵轴尺度：对数展开低频色阶；线性显示实际频率比例。横轴始终为 0–255。").accessibilityLabel("切换直方图纵轴尺度").accessibilityValue(logarithmic ? "对数" : "线性")
                ForEach(0..<4) { i in Text(["R","G","B","W"][i]).foregroundStyle(colors[i]).font(.system(size: 9,weight: .medium,design: .monospaced)) }
            }
            Canvas { context,size in
                let rect = CGRect(x: 1,y: 5,width: size.width-2,height: size.height-6)
                var grid = Path()
                for x in [0.0,0.25,0.5,0.75,1.0] { grid.move(to: CGPoint(x: rect.minX+rect.width*x,y: rect.minY)); grid.addLine(to: CGPoint(x: rect.minX+rect.width*x,y: rect.maxY)) }
                for y in [0.5,1.0] { grid.move(to: CGPoint(x: rect.minX,y: rect.minY+rect.height*y)); grid.addLine(to: CGPoint(x: rect.maxX,y: rect.minY+rect.height*y)) }
                context.stroke(grid,with: .color(.primary.opacity(0.13)),lineWidth: 0.5)
                guard let histogram else { return }
                let curves = histogram.curves(logarithmic: logarithmic)
                // Draw luminance underneath the three color channels.
                for channel in [3,0,1,2] {
                    var line = Path()
                    for i in 0..<256 {
                        let p = CGPoint(x: rect.minX+CGFloat(i)/255*rect.width,y: rect.maxY-curves[channel][i]*rect.height)
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    var fill = line; fill.addLine(to: CGPoint(x: rect.maxX,y: rect.maxY)); fill.addLine(to: CGPoint(x: rect.minX,y: rect.maxY)); fill.closeSubpath()
                    context.fill(fill,with: .color(colors[channel].opacity(channel == 3 ? 0.11 : dark ? 0.21 : 0.14)))
                    context.stroke(line,with: .color(colors[channel].opacity(channel == 3 ? 0.65 : 0.9)),lineWidth: 0.8)
                }
            }.frame(height: 100).padding(6)
                .background(Color(white: dark ? 0.15 : 0.965),in: plotShape)
                .overlay(plotShape.strokeBorder(Color.primary.opacity(0.10),lineWidth: 0.5).allowsHitTesting(false))
                .overlay { if histogram == nil { if loading { ProgressView().controlSize(.mini) } else { Text("无法读取直方图").font(.system(size: 10)).foregroundStyle(.secondary) } } }
                .accessibilityLabel("RGB 与亮度直方图").accessibilityValue(histogram == nil ? (loading ? "正在载入" : "无法读取") : "红、绿、蓝与亮度通道，"+(raw ? "RAW 显影" : "JPEG")+" sRGB，"+(logarithmic ? "对数" : "线性")+"纵轴")
            HStack { Text("0"); Spacer(); Text(raw ? "RAW 显影 · sRGB" : "JPEG · sRGB"); Spacer(); Text("255") }.font(.system(size: 9,design: .monospaced)).foregroundStyle(.secondary)
            if let histogram {
                HStack { Text(String(format: "黑端 %.1f%%",Double(histogram.channels[3][0])*100/Double(histogram.sampleCount))); Spacer(); Text(String(format: "白端 %.1f%%",Double(histogram.channels[3][255])*100/Double(histogram.sampleCount))) }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).help("当前显像中亮度值等于 0 / 255 的采样像素比例；RAW 为显影后的画面。")
            }
        }.accessibilityElement(children: .contain)
    }
}
