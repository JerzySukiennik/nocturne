// Nocturne: draws the app icon (flat crescent on black) into an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let dark = CGColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil))
    ctx.setFillColor(dark)
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.949, green: 0.847, blue: 0.541, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 512 - 230, y: 512 - 230, width: 460, height: 460))
    ctx.setFillColor(dark)
    ctx.fillEllipse(in: CGRect(x: 512 + 104 - 206, y: 512 + 78 - 206, width: 412, height: 412))
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
