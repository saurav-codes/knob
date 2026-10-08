// Draws the app icon, the menu bar dial on a dark tile, as a 1024 px PNG.
// Usage: swift Icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
  let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
  NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
    .draw(in: tilePath, angle: -90)

  let c = CGPoint(x: tile.midX, y: tile.midY)
  let accent = NSColor(red: 0.95, green: 0.55, blue: 0.3, alpha: 1)

  // Scale arc, open at the bottom like a volume dial.
  let scale = NSBezierPath()
  scale.lineWidth = 46
  scale.lineCapStyle = .round
  scale.appendArc(withCenter: c, radius: 290, startAngle: -50, endAngle: 230)
  accent.setStroke()
  scale.stroke()

  // Knob body.
  let knob = NSBezierPath(ovalIn: NSRect(x: c.x - 190, y: c.y - 190, width: 380, height: 380))
  NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.72, alpha: 1))!.draw(in: knob, angle: -90)

  // Pointer turned toward the high end of the scale.
  let pointer = NSBezierPath()
  pointer.lineWidth = 44
  pointer.lineCapStyle = .round
  pointer.move(to: CGPoint(x: c.x + 30 * cos(.pi / 4), y: c.y + 30 * sin(.pi / 4)))
  pointer.line(to: CGPoint(x: c.x + 130 * cos(.pi / 4), y: c.y + 130 * sin(.pi / 4)))
  NSColor(white: 0.12, alpha: 1).setStroke()
  pointer.stroke()
  return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
