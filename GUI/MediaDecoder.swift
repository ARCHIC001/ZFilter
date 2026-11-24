import Foundation
import CoreImage
import ImageIO

enum MediaDecoder {
    static let rawExtensions: Set<String> = ["nef","nrw","arw","sr2","srf","cr2","cr3","crw","dng","raf","rw2","orf","pef","ptx","rwl","erf","iiq","3fr","fff","mos","mrw","raw","srw","kdc","dcr"]
    static func isRAW(_ path: String) -> Bool { rawExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    static let context = CIContext(options: [.cacheIntermediates: false])
    struct Decoded {
        let image: CGImage
        let properties: [String: Any]
    }
    static func decode(_ path: String,maxPixelSize: Int? = nil) -> Decoded? {
        let url = URL(fileURLWithPath: path)
        if isRAW(path) {
            // Decode sensor data. Never substitute a companion JPEG or an
            // embedded camera preview for the full-resolution RAW view.
            guard let raw = CIRAWFilter(imageURL: url) else { return nil }
            if let maxPixelSize {
                raw.scaleFactor = Float(min(1,Double(maxPixelSize)/max(raw.nativeSize.width,raw.nativeSize.height)))
                raw.isDraftModeEnabled = true
            }
            guard let output = raw.outputImage,output.extent.width.isFinite,output.extent.height.isFinite,
                  output.extent.width>0,output.extent.height>0,
                  let image = context.createCGImage(output,from: output.extent,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
            return Decoded(image: image,properties: raw.properties as? [String: Any] ?? [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceCreateThumbnailWithTransform: true,kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? 20000,kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return Decoded(image: image,properties: CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String: Any] ?? [:])
    }
}
