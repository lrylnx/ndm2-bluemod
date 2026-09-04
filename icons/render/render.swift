import AppKit
let args = CommandLine.arguments
let svgDir = args[1], pngDir = args[2]
let fm = FileManager.default
let files = try! fm.contentsOfDirectory(atPath: svgDir).filter { $0.hasSuffix(".svg") && !$0.hasPrefix("_") }
var fail = 0
for file in files {
    let name = (file as NSString).deletingPathExtension
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: "\(svgDir)/\(file)")) else { print("FAIL \(file)"); fail += 1; continue }
    let px = 131
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail += 1; continue }
    try! png.write(to: URL(fileURLWithPath: "\(pngDir)/\(name).png"))
}
print("rendered \(files.count - fail), failed \(fail)")
exit(fail == 0 ? 0 : 1)
