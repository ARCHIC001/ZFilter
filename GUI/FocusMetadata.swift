import Foundation
import AppKit

// Nikon AFInfo2 layouts documented at https://exiftool.org/TagNames/Nikon.html.
// Only coordinates explicitly marked available are used; no face/center guessing.
struct FocusPoint {
    let x: Double // normalized display coordinates, origin at top left
    let y: Double
    let aspect: Double
    let version: String
    let inFocus: Bool?
    var areaSize: CGSize? = nil // fraction of the oriented image
    static func oriented(x: Double, y: Double, width: Double, height: Double, orientation: Int, version: String, inFocus: Bool?, area: CGSize? = nil) -> FocusPoint? {
        guard width > 0, height > 0, x >= 0, y >= 0, x <= width, y <= height else { return nil }
        let u = x/width, v = y/height
        let point: (Double, Double)
        switch orientation {
        case 1: point = (u,v)
        case 2: point = (1-u,v)
        case 3: point = (1-u,1-v)
        case 4: point = (u,1-v)
        case 5: point = (v,u)
        case 6: point = (1-v,u)
        case 7: point = (1-v,1-u)
        case 8: point = (v,1-u)
        default: return nil
        }
        let normalizedArea = area.map { size in
            orientation >= 5 ? CGSize(width: size.height/height, height: size.width/width) : CGSize(width: size.width/width, height: size.height/height)
        }
        return FocusPoint(x: point.0, y: point.1, aspect: orientation >= 5 ? height/width : width/height, version: version, inFocus: inFocus, areaSize: normalizedArea)
    }
}
struct RecordedFocus {
    var point: FocusPoint?
    var mode: String?
    var distance: Double? // metres; infinity is a defined lens value
    var areaMode: String?
    var inFocus: Bool?

    var rows: [(String, String)] {
        var rows = [("对焦距离", distance.map { d in
            d.isInfinite ? "∞（无穷远）" : String(format: d < 10 ? "约 %.2f m" : "约 %.1f m", d)
        } ?? "未记录")]
        if let mode { rows.append(("对焦模式", mode)) }
        if let area = areaMode { rows.append(("对焦区域", area)) }
        if let confirmed = inFocus { rows.append(("合焦记录", confirmed ? "已合焦" : "未合焦")) }
        rows.append(("对焦点", point == nil ? "未记录可用坐标" : "可用 · 按 0 放大"))
        return rows
    }
}

struct NikonPictureControl: Equatable {
    let name: String
    let base: String?

    var rows: [(String, String)] {
        var rows = [("色彩预设", name)]
        if let base, name.caseInsensitiveCompare(base) != .orderedSame { rows.append(("基础预设", base)) }
        return rows
    }

    // MakerNote 0x0023 uses 20-byte names with different offsets in V3.
    static func decode(_ bytes: ArraySlice<UInt8>) -> NikonPictureControl? {
        guard bytes.count >= 4 else { return nil }
        let offset: Int
        switch String(decoding: bytes.prefix(2), as: UTF8.self) {
        case "01", "02": offset = 4
        case "03": offset = 8
        default: return nil
        }
        guard bytes.count >= offset+40 else { return nil }
        func text(_ start: Int) -> String? {
            let field = bytes.dropFirst(start).prefix(20).prefix { $0 != 0 }
            let value = (String(bytes: field, encoding: .utf8) ?? String(bytes: field, encoding: .shiftJIS))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        guard let name = text(offset) else { return nil }
        return NikonPictureControl(name: name, base: text(offset+20))
    }
}

enum FocusMetadata {
    private static let areaModes = [192: "精确", 193: "单点", 195: "宽区域（小）", 196: "宽区域（大）", 197: "自动区域", 204: "动态区域（小）", 205: "动态区域（中）", 206: "动态区域（大）", 207: "3D 跟踪", 208: "宽区域（自定义）"]
    struct TIFF {
        let bytes: [UInt8]
        let base: Int
        let little: Bool
        init?(_ bytes: [UInt8], base: Int) {
            guard base >= 0, base + 8 <= bytes.count else { return nil }
            let signature = Array(bytes[base..<base+2])
            guard signature == [0x49,0x49] || signature == [0x4d,0x4d] else { return nil }
            self.bytes = bytes; self.base = base; self.little = signature[0] == 0x49
            guard u16(base+2) == 42 else { return nil }
        }
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset+2 <= bytes.count else { return nil }
            return little ? Int(bytes[offset]) | Int(bytes[offset+1]) << 8 : Int(bytes[offset]) << 8 | Int(bytes[offset+1])
        }
        func u32(_ offset: Int) -> Int? {
            guard let a=u16(offset), let b=u16(offset+2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        func entry(_ tag: Int, ifd: Int) -> (start: Int, length: Int, value: Int)? {
            guard ifd >= 0, ifd < bytes.count-base, let count = u16(base+ifd), count <= 4096 else { return nil }
            for i in 0..<count {
                let position = base+ifd+2+i*12
                guard position+12 <= bytes.count, let found=u16(position), let type=u16(position+2), let elements=u32(position+4), let value=u32(position+8) else { return nil }
                if found != tag { continue }
                guard let unit = [1:1,2:1,3:2,4:4,7:1][type], elements > 0, elements <= 524288/unit else { return nil }
                let length = elements*unit, start = length <= 4 ? position+8 : base+value
                guard start >= base, start <= bytes.count, length <= bytes.count-start else { return nil }
                let scalar = type == 3 ? u16(start) ?? 0 : value
                return (start,length,scalar)
            }
            return nil
        }
    }
    static func read(_ path: String) -> FocusPoint? {
        readHeader(path).flatMap(parse)
    }
    static func readHeader(_ path: String) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 1024*1024)
    }
    static func parse(_ data: Data) -> FocusPoint? {
        nikonHeader(data).flatMap(point)
    }
    private static func point(_ header: NikonHeader) -> FocusPoint? {
        guard let af = header.entry(0x00b7) else { return nil }
        return decodeAF(Array(header.tiff.bytes[af.start..<af.start+af.length]), little: header.tiff.little, orientation: header.orientation)
    }

    static func recorded(_ path: String) -> (focus: RecordedFocus, pictureControl: NikonPictureControl?) {
        guard let header = readHeader(path).flatMap(nikonHeader) else { return (RecordedFocus(), nil) }
        let mode = header.string(0x0007)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var focus = RecordedFocus(point: point(header), mode: mode?.isEmpty == false ? mode : nil,
                                  distance: NikonLensDistance.read(header))
        if let af = header.entry(0x00b7), af.length > 74 {
            let bytes = header.tiff.bytes
            if ["0400", "0401", "0402"].contains(String(decoding: bytes[af.start..<af.start+4], as: UTF8.self)) {
                focus.areaMode = areaModes[Int(bytes[af.start+5])]
                let result = bytes[af.start+74]
                focus.inFocus = result <= 1 ? result == 1 : nil
            }
        }
        let pictureControl = header.entry(0x0023).flatMap { field in
            NikonPictureControl.decode(header.tiff.bytes[field.start..<field.start+field.length])
        }
        return (focus, pictureControl)
    }

    struct NikonHeader {
        let tiff: TIFF
        let ifd: Int
        let end: Int
        let orientation: Int

        func entry(_ tag: Int) -> (start: Int, length: Int, value: Int)? {
            guard let entry = tiff.entry(tag, ifd: ifd), entry.start+entry.length <= end else { return nil }
            return entry
        }
        func string(_ tag: Int) -> String? {
            guard let field = entry(tag) else { return nil }
            return String(bytes: tiff.bytes[field.start..<field.start+field.length].prefix { $0 != 0 }, encoding: .ascii)
        }
    }

    static func nikonHeader(_ data: Data) -> NikonHeader? {
        let bytes = [UInt8](data)
        var base = 0
        if bytes.starts(with: [0xff,0xd8]) {
            var position = 2, exifBase: Int?
            while position+4 <= bytes.count {
                guard bytes[position] == 0xff else { return nil }
                let marker = bytes[position+1]; position += 2
                if marker == 0xda || marker == 0xd9 { break }
                if marker == 0xff { position -= 1; continue }
                if marker == 0xd8 || marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
                let length = Int(bytes[position]) << 8 | Int(bytes[position+1])
                guard length >= 2, length <= bytes.count-position else { return nil }
                if marker == 0xe1, length >= 8, Array(bytes[position+2..<position+8]) == [69,120,105,102,0,0] { exifBase = position+8; break }
                position += length
            }
            guard let start = exifBase else { return nil }; base = start
        }
        guard let tiff = TIFF(bytes, base: base), let first=tiff.u32(base+4), let exif=tiff.entry(0x8769, ifd: first), let maker=tiff.entry(0x927c, ifd: exif.value), maker.length >= 18,
              Array(bytes[maker.start..<maker.start+6]) == [78,105,107,111,110,0],
              let nikon=TIFF(bytes, base: maker.start+10), let nikonIFD=nikon.u32(nikon.base+4) else { return nil }
        let orientation = tiff.entry(0x0112, ifd: first)?.value ?? 1
        return NikonHeader(tiff: nikon, ifd: nikonIFD, end: maker.start+maker.length, orientation: orientation)
    }
    static func decodeAF(_ bytes: [UInt8], little: Bool, orientation: Int) -> FocusPoint? {
        guard bytes.count >= 8, bytes[7] == 1, let version=String(bytes: bytes.prefix(4), encoding: .ascii) else { return nil }
        let start: Int
        switch version { case "0300", "0301": start=42; case "0400", "0401", "0402": start=62; default: return nil }
        guard bytes.count >= start+12 else { return nil }
        func short(_ offset: Int) -> Double { Double(little ? Int(bytes[offset]) | Int(bytes[offset+1]) << 8 : Int(bytes[offset]) << 8 | Int(bytes[offset+1])) }
        let width=short(start), height=short(start+2), x=short(start+4), y=short(start+6)
        guard width > 0, height > 0, x > 0 || y > 0 else { return nil }
        let areaWidth = short(start+8), areaHeight = short(start+10)
        let area = areaWidth > 0 && areaHeight > 0 && areaWidth <= width && areaHeight <= height ? CGSize(width: areaWidth,height: areaHeight) : nil
        let modern = version.hasPrefix("04")
        let inFocus: Bool? = modern && bytes.count > 74 && bytes[74] <= 1 ? bytes[74] == 1 : nil
        return FocusPoint.oriented(x: x, y: y, width: width, height: height, orientation: orientation, version: version, inFocus: inFocus, area: area)
    }
}
extension Notification.Name {
    static let filterFocusZoom = Notification.Name("studio.filter.focusZoom")
    static let filterFitImage = Notification.Name("studio.filter.fitImage")
}
