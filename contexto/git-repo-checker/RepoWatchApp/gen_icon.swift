import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).addClip()

// Fondo con degradado (menos plano que un color sólido) + brillo superior,
// para un look más pulido/3D en vez del cuadrado de color sólido de antes.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.46, green: 0.36, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.22, green: 0.15, blue: 0.64, alpha: 1.0),
])!
gradient.draw(in: rect, angle: -90)

let gloss = NSBezierPath()
gloss.move(to: NSPoint(x: 0, y: size))
gloss.line(to: NSPoint(x: size, y: size))
gloss.line(to: NSPoint(x: size, y: size * 0.6))
gloss.curve(to: NSPoint(x: 0, y: size * 0.6),
            controlPoint1: NSPoint(x: size * 0.6, y: size * 0.78),
            controlPoint2: NSPoint(x: size * 0.4, y: size * 0.78))
gloss.close()
NSColor.white.withAlphaComponent(0.16).setFill()
gloss.fill()

// Sombra sutil bajo el símbolo, para separarlo del fondo.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = size * 0.035
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
shadow.set()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .semibold)
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
