// Editable vector master: all geometry is expressed in a 1024-point square.
// Regenerates a vector PDF and every ICNS resolution, without cropping the source JPG.
import AppKit
import ImageIO
import UniformTypeIdentifiers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red:r,green:g,blue:b,alpha:a) }
func drawIcon(_ c: CGContext) {
    c.saveGState(); c.translateBy(x:0,y:1024); c.scaleBy(x:1,y:-1)
    let tile = CGPath(roundedRect: CGRect(x:100,y:100,width:824,height:824), cornerWidth:180, cornerHeight:180, transform:nil)
    c.setShadow(offset: CGSize(width:0,height:8), blur:14, color:color(0,0,0,0.34))
    c.addPath(tile); c.setFillColor(color(0.025,0.04,0.085)); c.fillPath(); c.setShadow(offset:.zero,blur:0,color:nil)
    let space = CGColorSpace(name:CGColorSpace.sRGB)!
    func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
        c.drawLinearGradient(CGGradient(colorsSpace:space, colors:colors as CFArray, locations:nil)!, start:from,end:to,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    }
    c.saveGState(); c.addPath(tile); c.clip()
    gradient([color(0.20,0.27,0.39),color(0.045,0.09,0.17),color(0.008,0.018,0.045)],from:CGPoint(x:220,y:100),to:CGPoint(x:750,y:900))
    c.restoreGState()
    c.addPath(tile); c.setStrokeColor(color(0.40,0.51,0.67,0.65)); c.setLineWidth(3); c.strokePath()
    let z = CGMutablePath()
    z.move(to:CGPoint(x:230,y:224)); z.addLine(to:CGPoint(x:806,y:224)); z.addLine(to:CGPoint(x:401,y:750)); z.addLine(to:CGPoint(x:806,y:750)); z.addLine(to:CGPoint(x:806,y:810))
    z.addQuadCurve(to:CGPoint(x:776,y:840),control:CGPoint(x:806,y:840)); z.addLine(to:CGPoint(x:250,y:840)); z.addQuadCurve(to:CGPoint(x:206,y:796),control:CGPoint(x:206,y:840))
    z.addLine(to:CGPoint(x:206,y:766)); z.addQuadCurve(to:CGPoint(x:220,y:724),control:CGPoint(x:206,y:744)); z.addLine(to:CGPoint(x:565,y:294)); z.addLine(to:CGPoint(x:206,y:294)); z.addLine(to:CGPoint(x:206,y:252)); z.addQuadCurve(to:CGPoint(x:230,y:224),control:CGPoint(x:206,y:224)); z.closeSubpath()
    c.saveGState(); c.translateBy(x:16,y:14); c.addPath(z); c.setFillColor(color(0.015,0.027,0.062)); c.fillPath(); c.restoreGState()
    c.saveGState(); c.addPath(z); c.clip()
    gradient([color(0.96,0.98,1),color(0.57,0.64,0.73),color(0.88,0.92,0.96),color(0.34,0.41,0.53)],from:CGPoint(x:260,y:240),to:CGPoint(x:820,y:850))
    c.restoreGState(); c.addPath(z); c.setLineWidth(1.8); c.setStrokeColor(color(0.96,0.98,1,0.65)); c.strokePath()
    c.restoreGState()
}
let output = URL(fileURLWithPath:CommandLine.arguments[1])
let fm = FileManager.default
let iconset = output.appendingPathComponent("ZFilter.iconset")
try fm.createDirectory(at:iconset,withIntermediateDirectories:true)
var media = CGRect(x:0,y:0,width:1024,height:1024)
let pdf = output.appendingPathComponent("AppIcon.pdf")
let context = CGContext(pdf as CFURL,mediaBox:&media,nil)!
context.beginPDFPage(nil); drawIcon(context); context.endPDFPage(); context.closePDF()
func png(_ size: Int, _ url: URL) {
    let c = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024); drawIcon(c)
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,c.makeImage()!,nil); precondition(CGImageDestinationFinalize(destination))
}
for size in [16,32,128,256,512] {
    png(size,iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    png(size*2,iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
png(1024,output.appendingPathComponent("AppIcon.png"))
print("Vector PDF and transparent ICNS assets generated")
