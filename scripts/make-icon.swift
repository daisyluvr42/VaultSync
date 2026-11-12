import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext; context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 48,y: 48,width: 928,height: 928), xRadius: 216,yRadius: 216)
        NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.23, blue: 0.85, alpha: 1), ending: NSColor(calibratedRed: 0.55,green: 0.44,blue: 1,alpha: 1))!.draw(in: background, angle: 55)
        NSColor.white.setStroke(); NSColor.white.setFill()
        let lines = NSBezierPath(); lines.lineWidth = 52; lines.lineCapStyle = .round; lines.lineJoinStyle = .round
        lines.move(to: NSPoint(x:512,y:280)); lines.line(to: NSPoint(x:512,y:490)); lines.curve(to:NSPoint(x:320,y:720),controlPoint1:NSPoint(x:512,y:630),controlPoint2:NSPoint(x:320,y:580))
        lines.move(to:NSPoint(x:512,y:490)); lines.curve(to:NSPoint(x:704,y:720),controlPoint1:NSPoint(x:512,y:630),controlPoint2:NSPoint(x:704,y:580)); lines.stroke()
        for point in [NSPoint(x:512,y:280),NSPoint(x:320,y:720),NSPoint(x:704,y:720)] { NSBezierPath(ovalIn: NSRect(x:point.x-54,y:point.y-54,width:108,height:108)).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
    }
}
