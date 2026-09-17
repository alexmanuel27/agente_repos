import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
NSColor(calibratedRed: 0.29, green: 0.24, blue: 0.85, alpha: 1.0).setFill()
rect.fill()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symSize = symbol.size
    let origin = NSPoint(x: (size - symSize.width) / 2, y: (size - symSize.height) / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("no se pudo generar el PNG")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
