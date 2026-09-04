import AppKit
// args: svgPath px outputPath
let svgPath = CommandLine.arguments[1]
let px = Int(CommandLine.arguments[2])!
let outPath = CommandLine.arguments[3]
guard let img = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else { print("FAIL load \(svgPath)"); exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { print("FAIL enc"); exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("OK \(outPath) \(px)px")
