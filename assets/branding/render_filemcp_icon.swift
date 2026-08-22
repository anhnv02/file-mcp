import AppKit

private let canvasSize = 1024
private let canvasRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func drawBrandGlyph() {
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 300, y: 344))
    folder.line(to: NSPoint(x: 300, y: 644))
    folder.curve(
        to: NSPoint(x: 362, y: 707),
        controlPoint1: NSPoint(x: 300, y: 679),
        controlPoint2: NSPoint(x: 328, y: 707)
    )
    folder.line(to: NSPoint(x: 478, y: 707))
    folder.line(to: NSPoint(x: 544, y: 627))
    folder.line(to: NSPoint(x: 664, y: 627))
    folder.curve(
        to: NSPoint(x: 724, y: 567),
        controlPoint1: NSPoint(x: 697, y: 627),
        controlPoint2: NSPoint(x: 724, y: 600)
    )
    folder.line(to: NSPoint(x: 724, y: 344))

    let monogram = NSBezierPath()
    monogram.move(to: NSPoint(x: 300, y: 524))
    monogram.line(to: NSPoint(x: 512, y: 344))
    monogram.line(to: NSPoint(x: 724, y: 524))

    for path in [folder, monogram] {
        path.lineWidth = 72
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color(255, 255, 255).setStroke()
        path.stroke()
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render_filemcp_icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("ERROR: could not create the icon drawing context.\n", stderr)
    exit(1)
}

bitmap.size = canvasRect.size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
color(0, 0, 0, alpha: 0).setFill()
canvasRect.fill()

let iconRect = NSRect(x: 80, y: 80, width: 864, height: 864)
let surface = NSBezierPath(roundedRect: iconRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(7, 31, 42, alpha: 0.22)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
color(21, 154, 156).setFill()
surface.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    color(13, 145, 166),
    color(32, 170, 160),
    color(99, 201, 119),
])
gradient?.draw(in: surface, angle: 38)

drawBrandGlyph()
NSGraphicsContext.restoreGraphicsState()

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("ERROR: could not encode the icon as PNG.\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
print("Built: \(outputURL.path)")
