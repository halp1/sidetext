import AppKit
// Renders a simple speech-bubble app icon into Resources/AppIcon.iconset, then iconutil builds the .icns.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.80, alpha: 1)])!.draw(in: bg, angle: -90)
    let b = NSRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.3, width: rect.width * 0.6, height: rect.height * 0.45)
    let bubble = NSBezierPath(roundedRect: b, xRadius: b.height * 0.45, yRadius: b.height * 0.45)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: b.minX + b.width * 0.22, y: b.minY + 2))
    tail.line(to: NSPoint(x: b.minX + b.width * 0.08, y: b.minY - b.height * 0.28))
    tail.line(to: NSPoint(x: b.minX + b.width * 0.42, y: b.minY + 2))
    tail.close()
    NSColor.white.setFill(); bubble.fill(); tail.fill()
    let dot = b.height * 0.16
    NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.9, alpha: 1).setFill()
    for i in -1...1 {
        let c = NSPoint(x: b.midX + CGFloat(i) * dot * 2.1, y: b.midY)
        NSBezierPath(ovalIn: NSRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
