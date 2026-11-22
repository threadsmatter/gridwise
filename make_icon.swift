// Draws Gridwise's icon (a sun setting behind a power line) at every size macOS wants, into AppIcon.iconset.
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.04, green: 0.10, blue: 0.20, alpha: 1), NSColor(red: 0.05, green: 0.25, blue: 0.30, alpha: 1)])!.draw(in: tile, angle: 90)
    tile.addClip()
    let sun = NSBezierPath(ovalIn: NSRect(x: s * 0.27, y: s * 0.30, width: s * 0.46, height: s * 0.46))
    NSGradient(colors: [NSColor(red: 1.0, green: 0.84, blue: 0.30, alpha: 1), NSColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1)])!.draw(in: sun, angle: -90)
    NSColor(red: 0.04, green: 0.10, blue: 0.20, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: s, height: s * 0.36).fill()
    NSColor(red: 0.0, green: 0.90, blue: 0.66, alpha: 1).setFill()
    NSRect(x: s * 0.18, y: s * 0.355, width: s * 0.64, height: max(1, s * 0.022)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
