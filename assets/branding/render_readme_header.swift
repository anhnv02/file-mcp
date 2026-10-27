import AppKit

// Fixed light canvas keeps the existing wordmark readable in every Markdown theme.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let size = NSSize(width: 1600, height: 320)
let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let logo = NSImage(contentsOf: root.appendingPathComponent("assets/branding/filemcp-v2/wordmark-light.png"))!
logo.draw(in: NSRect(x: (1600 - 483) / 2, y: 115, width: 483, height: 160))
func centered(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (text as NSString).size(withAttributes: attrs).width
    (text as NSString).draw(at: NSPoint(x: x - width / 2, y: y), withAttributes: attrs)
}
centered("Your local workspace, connected to ChatGPT. On your terms.", x: 800, y: 64,
         font: .systemFont(ofSize: 30, weight: .semibold), color: .black)
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("assets/branding/filemcp-v2/readme-header.png"))
