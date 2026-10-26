import AppKit

// Shared vector geometry: a compact document with a custom folded M monogram.
private let black = "000000", white = "FFFFFF", ink = "000000", paper = "F5F5F5"
private let accent = "DB0F30", accentLight = "F45C75", accentDeep = "A90925", accentBack = "F6A9B8", accentMiddle = "ED6480"
private let fileManager = FileManager.default
private let documentPath = "M68 58H156L200 102V198Q200 210 188 210H68Q56 210 56 198V70Q56 58 68 58Z"
private let monogramGeometry = roundedMonogram()
private let monogramPath = monogramGeometry.svg

private func roundedMonogram() -> (native: NSBezierPath, svg: String) {
    let raw: [(CGFloat, CGFloat)] = [(84,174),(84,124),(96,112),(104,112),(128,140),(152,112),(160,112),(172,124),(172,174),(154,174),(154,142),(128,170),(102,142),(102,174)]
    let points = raw.map { NSPoint(x: 128 + ($0.0 - 128) * 0.9, y: 137 + ($0.1 - 143) * 0.9) }
    func near(_ vertex: NSPoint, _ other: NSPoint) -> NSPoint {
        let dx = other.x - vertex.x, dy = other.y - vertex.y
        let distance = hypot(dx, dy)
        let amount = min(1.8, distance * 0.3) / distance
        return NSPoint(x: vertex.x + dx * amount, y: vertex.y + dy * amount)
    }
    func coords(_ point: NSPoint) -> String { String(format: "%.3f %.3f", Double(point.x), Double(point.y)) }
    let path = NSBezierPath()
    var svg = ""
    for index in points.indices {
        let vertex = points[index]
        let entry = near(vertex, points[(index + points.count - 1) % points.count])
        let exit = near(vertex, points[(index + 1) % points.count])
        if index == 0 { path.move(to: entry); svg += "M" + coords(entry) }
        else { path.line(to: entry); svg += "L" + coords(entry) }
        path.curve(to: exit,
            controlPoint1: NSPoint(x: entry.x + (vertex.x - entry.x) * 2 / 3, y: entry.y + (vertex.y - entry.y) * 2 / 3),
            controlPoint2: NSPoint(x: exit.x + (vertex.x - exit.x) * 2 / 3, y: exit.y + (vertex.y - exit.y) * 2 / 3))
        svg += "Q" + coords(vertex) + " " + coords(exit)
    }
    path.close(); return (path, svg + "Z")
}

private func color(_ value: String, alpha: CGFloat = 1) -> NSColor {
    let number = UInt32(value, radix: 16)!
    return NSColor(srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
                   blue: CGFloat(number & 255) / 255, alpha: alpha)
}

private func document() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 68, y: 58)); p.line(to: NSPoint(x: 156, y: 58)); p.line(to: NSPoint(x: 200, y: 102)); p.line(to: NSPoint(x: 200, y: 198))
    p.curve(to: NSPoint(x: 188, y: 210), controlPoint1: NSPoint(x: 200, y: 206), controlPoint2: NSPoint(x: 196, y: 210))
    p.line(to: NSPoint(x: 68, y: 210))
    p.curve(to: NSPoint(x: 56, y: 198), controlPoint1: NSPoint(x: 60, y: 210), controlPoint2: NSPoint(x: 56, y: 206))
    p.line(to: NSPoint(x: 56, y: 70))
    p.curve(to: NSPoint(x: 68, y: 58), controlPoint1: NSPoint(x: 56, y: 62), controlPoint2: NSPoint(x: 60, y: 58))
    p.close(); return p
}

private func drawRawMark(in rect: NSRect, main: String, small: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.maxY)
    transform.scaleX(by: rect.width / 256, yBy: -rect.height / 256)
    transform.concat()
    if main == accent {
        for (angle, dx, dy, fill) in [(-10.0, -3.0, -8.0, accentBack)] {
            NSGraphicsContext.saveGraphicsState()
            let rear = NSAffineTransform()
            rear.translateX(by: 128, yBy: 128); rear.rotate(byDegrees: CGFloat(angle)); rear.translateX(by: -128 + dx, yBy: -128 + dy); rear.concat()
            color(fill).setFill(); document().fill()
            color(white, alpha: 0.35).setStroke(); let edge = document(); edge.lineWidth = 0.8; edge.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(colors: [color(accentLight), color(accent), color(accentDeep)])!.draw(in: document(), angle: 90)
        color(white, alpha: 0.20).setStroke()
        let edge = document(); edge.lineWidth = 1.5; edge.stroke()
        color(white).setFill(); color(white).setStroke()
    } else {
        color(main).setFill(); document().fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
    }
    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 156, y: 74)); fold.line(to: NSPoint(x: 156, y: 102)); fold.line(to: NSPoint(x: 184, y: 102)); fold.close(); fold.fill()
    monogramGeometry.native.fill()
    NSGraphicsContext.restoreGraphicsState()
}

private func drawMark(in rect: NSRect, main: String) {
    // Render cutouts offscreen so transparent holes never erase the parent surface.
    let size = max(16, Int(ceil(rect.width)))
    let data = try! png(width: size, height: size) { drawRawMark(in: $0, main: main, small: size <= 32) }
    NSImage(data: data)!.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

private func drawIcon(in rect: NSRect) {
    color(white).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.078125, dy: rect.height * 0.078125), xRadius: rect.width * 0.1914, yRadius: rect.height * 0.1914).fill()
    drawMark(in: rect, main: accent)
}

private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, foreground: String, weight: NSFont.Weight = .regular, kern: CGFloat = 0) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(foreground), .kern: kern])
}

private let wordmarkFont = NSFont.systemFont(ofSize: 80, weight: .semibold)
private let wordmarkTextWidth = ("FileMCP" as NSString).size(withAttributes: [.font: wordmarkFont, .kern: -2.4]).width
private var wordmarkWidth: CGFloat { ceil(176 + wordmarkTextWidth + 28) }

private func drawWordmark(at origin: NSPoint, scale: CGFloat, dark: Bool = false, mono: Bool = false) {
    let main = mono ? (dark ? white : black) : accent
    drawMark(in: NSRect(x: origin.x, y: origin.y, width: 160 * scale, height: 160 * scale), main: main)
    text("FileMCP", x: origin.x + 176 * scale, y: origin.y + 31 * scale, size: 80 * scale, foreground: dark ? "FFFFFF" : ink, weight: .semibold, kern: -2.4 * scale)
}

private func png(width: Int, height: Int, draw: (NSRect) -> Void) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "FileMCP.Brand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create image context"])
    }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState(); context.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "FileMCP.Brand", code: 2) }
    return data
}

private func write(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func markSVG(main: String) -> String {
    if main == accent {
        return "<defs><linearGradient id=\"crimson\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop stop-color=\"#\(accentLight)\"/><stop offset=\".5\" stop-color=\"#\(accent)\"/><stop offset=\"1\" stop-color=\"#\(accentDeep)\"/></linearGradient></defs><path d=\"\(documentPath)\" fill=\"#\(accentBack)\" stroke=\"white\" stroke-opacity=\".35\" stroke-width=\".8\" transform=\"rotate(-10 128 128) translate(-3 -8)\"/><path d=\"\(documentPath)\" fill=\"url(#crimson)\" stroke=\"white\" stroke-opacity=\".2\" stroke-width=\"1.5\"/><path d=\"M156 74V102H184Z\" fill=\"white\"/><path d=\"\(monogramPath)\" fill=\"white\"/>"
    }
    return     "<defs><mask id=\"document-cutouts\"><path d=\"\(documentPath)\" fill=\"white\"/><path d=\"M156 74V102H184Z\" fill=\"black\"/><path d=\"\(monogramPath)\" fill=\"black\"/></mask></defs><path d=\"\(documentPath)\" fill=\"#\(main)\" mask=\"url(#document-cutouts)\"/>"
}
private func svg(width: Int, height: Int, title: String, content: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"\(title)\">\(content)</svg>\n"
}

private func iconICO() throws -> Data {
    let sizes = [16, 24, 32, 48, 64, 128, 256]
    let images = try sizes.map { size in try png(width: size, height: size) { drawIcon(in: $0) } }
    var data = Data()
    func append16(_ value: Int) { data.append(UInt8(value & 255)); data.append(UInt8((value >> 8) & 255)) }
    func append32(_ value: Int) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) } }
    append16(0); append16(1); append16(sizes.count)
    var offset = 6 + 16 * sizes.count
    for (size, image) in zip(sizes, images) {
        data.append(size == 256 ? 0 : UInt8(size)); data.append(size == 256 ? 0 : UInt8(size))
        data.append(0); data.append(0); append16(1); append16(32); append32(image.count); append32(offset)
        offset += image.count
    }
    for image in images { data.append(image) }
    return data
}

private func brandBoard() throws -> Data {
    try png(width: 1800, height: 1240) { rect in
        color("EEEEEE").setFill(); rect.fill()
        text("FILEMCP / FOLDED M / CRIMSON", x: 64, y: 1160, size: 22, foreground: ink, weight: .semibold, kern: 2)
        text("Local files. Connected to your AI tools.", x: 64, y: 1122, size: 20, foreground: "666666")
        func card(_ frame: NSRect, _ fill: String) { color(fill).setFill(); NSBezierPath(roundedRect: frame, xRadius: 24, yRadius: 24).fill() }
        card(NSRect(x: 64, y: 660, width: 824, height: 410), "FFFFFF")
        card(NSRect(x: 912, y: 660, width: 824, height: 410), ink)
        text("LIGHT", x: 100, y: 1012, size: 14, foreground: "666666", weight: .medium, kern: 2)
        text("DARK", x: 948, y: 1012, size: 14, foreground: "AAAAAA", weight: .medium, kern: 2)
        let scale = min(1.22, 720 / wordmarkWidth)
        drawWordmark(at: NSPoint(x: 64 + (824 - wordmarkWidth * scale) / 2, y: 770), scale: scale)
        drawWordmark(at: NSPoint(x: 912 + (824 - wordmarkWidth * scale) / 2, y: 770), scale: scale, dark: true)
        card(NSRect(x: 64, y: 210, width: 520, height: 426), "FFFFFF")
        card(NSRect(x: 608, y: 210, width: 520, height: 426), "FFFFFF")
        card(NSRect(x: 1152, y: 210, width: 584, height: 426), "FFFFFF")
        text("APP ICON", x: 100, y: 578, size: 14, foreground: "666666", weight: .medium, kern: 2)
        drawIcon(in: NSRect(x: 169, y: 258, width: 310, height: 310))
        text("SYMBOL DETAIL", x: 644, y: 578, size: 14, foreground: "666666", weight: .medium, kern: 2)
        drawMark(in: NSRect(x: 718, y: 264, width: 300, height: 300), main: ink)
        text("SMALL BY DESIGN", x: 1188, y: 578, size: 14, foreground: "666666", weight: .medium, kern: 2)
        var x: CGFloat = 1198
        for size in [32, 64, 128] {
            drawIcon(in: NSRect(x: x, y: 350, width: CGFloat(size), height: CGFloat(size)))
            text("\(size) px", x: x, y: 308, size: 16, foreground: "666666")
            x += CGFloat(size) + 62
        }
        for (index, entry) in [(accent, "Crimson"), (accentLight, "Highlight"), (accentDeep, "Shade"), ("FFFFFF", "White")].enumerated() {
            let x = 64 + CGFloat(index) * 428
            color(entry.0).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 86, width: 52, height: 52), xRadius: 12, yRadius: 12).fill()
            text(entry.1, x: x + 72, y: 112, size: 18, foreground: ink, weight: .semibold)
            text("#" + entry.0, x: x + 72, y: 86, size: 16, foreground: "666666")
        }
    }
}

private func exportKit(to directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, main, dark, mono) in [
        ("light", accent, false, false), ("dark", accent, true, false),
        ("mono", ink, false, true), ("white", "FFFFFF", true, true),
    ] {
        let mark = markSVG(main: main)
        try write(Data(svg(width: 256, height: 256, title: "FileMCP symbol", content: mark).utf8), to: directory.appendingPathComponent("mark-\(name).svg"))
        try write(png(width: 512, height: 512) { drawMark(in: $0, main: main) }, to: directory.appendingPathComponent("mark-\(name).png"))
        let wordmark = "<g transform=\"scale(.625)\">\(mark)</g><text x=\"176\" y=\"109\" fill=\"#\(dark ? "FFFFFF" : ink)\" font-family=\"Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,sans-serif\" font-size=\"80\" font-weight=\"600\" letter-spacing=\"-2.4\">FileMCP</text>"
        try write(Data(svg(width: Int(wordmarkWidth), height: 160, title: "FileMCP", content: wordmark).utf8), to: directory.appendingPathComponent("wordmark-\(name).svg"))
        try write(png(width: Int(wordmarkWidth * 2), height: 320) { _ in drawWordmark(at: .zero, scale: 2, dark: dark, mono: mono) }, to: directory.appendingPathComponent("wordmark-\(name).png"))
    }
    let icon = "<rect x=\"80\" y=\"80\" width=\"864\" height=\"864\" rx=\"196\" fill=\"white\"/><g transform=\"scale(4)\">\(markSVG(main: accent))</g>"
    try write(Data(svg(width: 1024, height: 1024, title: "FileMCP app icon", content: icon).utf8), to: directory.appendingPathComponent("app-icon.svg"))
    try write(Data(svg(width: 256, height: 256, title: "FileMCP favicon", content: markSVG(main: accent)).utf8), to: directory.appendingPathComponent("favicon.svg"))
    for size in [16, 24, 32, 48, 64, 128, 256, 512, 1024] {
        try write(png(width: size, height: size) { drawIcon(in: $0) }, to: directory.appendingPathComponent("app-icon-\(size).png"))
    }
    try write(iconICO(), to: directory.appendingPathComponent("FileMCP.ico"))
    try write(brandBoard(), to: directory.appendingPathComponent("brand-board.png"))
}

let args = CommandLine.arguments
if args.count == 3 && args[1] == "--brand-kit" {
    try exportKit(to: URL(fileURLWithPath: args[2], isDirectory: true))
    print("Built brand kit: \(args[2])")
} else if args.count == 2 {
    try write(png(width: 1024, height: 1024) { drawIcon(in: $0) }, to: URL(fileURLWithPath: args[1]))
    print("Built: \(args[1])")
} else {
    fputs("usage: render_filemcp_icon.swift <output.png> | --brand-kit <directory>\n", stderr)
    exit(2)
}
