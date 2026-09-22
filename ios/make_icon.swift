// Render the website's pine-cone mark as an opaque iOS app icon.
// Run from ios/: swift make_icon.swift
import Foundation
import CoreGraphics
import ImageIO

let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.scaleBy(x: 16, y: 16)
ctx.translateBy(x: 0, y: 64)
ctx.scaleBy(x: 1, y: -1)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1)
}
ctx.setFillColor(color(37,48,27))
ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
ctx.setStrokeColor(color(217,172,107))
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x:32,y:48)); ctx.addLine(to: CGPoint(x:32,y:55)); ctx.strokePath()
ctx.setFillColor(color(217,172,107))
ctx.move(to: CGPoint(x:32,y:8))
ctx.addCurve(to: CGPoint(x:15,y:37), control1: CGPoint(x:24,y:12), control2: CGPoint(x:15,y:25))
ctx.addCurve(to: CGPoint(x:32,y:53), control1: CGPoint(x:15,y:47), control2: CGPoint(x:22,y:53))
ctx.addCurve(to: CGPoint(x:49,y:37), control1: CGPoint(x:42,y:53), control2: CGPoint(x:49,y:47))
ctx.addCurve(to: CGPoint(x:32,y:8), control1: CGPoint(x:49,y:25), control2: CGPoint(x:40,y:12))
ctx.closePath(); ctx.fillPath()
ctx.setStrokeColor(color(107,72,39)); ctx.setLineWidth(3); ctx.setLineJoin(.round)
for row: [(CGFloat,CGFloat)] in [ [(24,20),(32,26),(40,20)],
    [(19,29),(26,35),(32,30),(38,35),(45,29)],
    [(19,40),(26,45),(32,40),(38,45),(45,40)] ] {
    ctx.move(to: CGPoint(x:row[0].0,y:row[0].1))
    for p in row.dropFirst() { ctx.addLine(to: CGPoint(x:p.0,y:p.1)) }
    ctx.strokePath()
}
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "SeedFinder/Assets.xcassets/AppIcon.appiconset/AppIcon.png") as CFURL,
    "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Could not save app icon")
