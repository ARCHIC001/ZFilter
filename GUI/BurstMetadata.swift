import Foundation

struct BurstID: Hashable {
    let camera: String
    let start: Int
    let shutter: Int
}

enum BurstMetadata {
    static func collapsed<T>(_ rows: [T], ids: [String: BurstID], isCollapsed: (BurstID) -> Bool,
                             preferred: (BurstID) -> String?, path: (T) -> String) -> [T] {
        var slots: [BurstID: Int] = [:]
        var visible: [T] = []
        visible.reserveCapacity(rows.count)
        for row in rows {
            let key = path(row)
            if let id = ids[key], isCollapsed(id) {
                if let slot = slots[id] {
                    if preferred(id) == key { visible[slot] = row }
                    continue
                }
                slots[id] = visible.count
            }
            visible.append(row)
        }
        return visible
    }
    static func read(_ path: String) -> BurstID? {
        guard let data = FocusMetadata.readHeader(path), let header = FocusMetadata.nikonHeader(data),
              let info = header.entry(0x0056), info.length >= 12,
              let serial = header.entry(0x001d), let shutter = header.entry(0x00a7) else { return nil }
        let camera = String(decoding: header.tiff.bytes[serial.start..<serial.start+serial.length].prefix { $0 != 0 }, as: UTF8.self)
        return identify(camera: camera, start: header.tiff.u32(info.start+4), shot: header.tiff.u32(info.start+8), shutter: shutter.value)
    }

    // Nikon Z8/Z9 MakerNote 0x0056. The packed start includes card slot,
    // folder, file number and type. The shutter count distinguishes wraps.
    static func identify(camera: String, start: Int?, shot: Int?, shutter: Int) -> BurstID? {
        guard !camera.isEmpty, let start, let shot, start != 0,
              (start & 0x0007ffe0) != 0, shot > 0, shutter >= shot else { return nil }
        return BurstID(camera: camera, start: start, shutter: shutter-shot)
    }
}
