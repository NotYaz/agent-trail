import AppKit

let destination = CommandLine.arguments[1]
let manager = FileManager.default
try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1))!.draw(in: background, angle: -60)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 320, y: 325))
        path.line(to: NSPoint(x: 512, y: 690))
        path.line(to: NSPoint(x: 714, y: 325))
        path.line(to: NSPoint(x: 320, y: 325))
        path.lineWidth = 30
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.77).setStroke()
        path.stroke()
        for (point, color) in [
            (NSPoint(x: 320, y: 325), NSColor(calibratedRed: 0.43, green: 0.64, blue: 1, alpha: 1)),
            (NSPoint(x: 512, y: 690), NSColor(calibratedRed: 0.91, green: 0.96, blue: 1, alpha: 1)),
            (NSPoint(x: 714, y: 325), NSColor(calibratedRed: 1, green: 0.65, blue: 0.40, alpha: 1))
        ] {
            NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.17, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 76, y: point.y - 76, width: 152, height: 152)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 53, y: point.y - 53, width: 106, height: 106)).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
