import AppKit
// Render into fixed pixels; NSImage.lockFocus follows the display's Retina scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedRed:0.12,green:0.31,blue:0.23,alpha:1).setFill()
NSBezierPath(rect:NSRect(x:0,y:0,width:1024,height:1024)).fill()
NSColor(calibratedRed:0.83,green:0.94,blue:0.59,alpha:1).setFill()
let leaf=NSBezierPath();leaf.move(to:NSPoint(x:310,y:280));leaf.curve(to:NSPoint(x:750,y:760),controlPoint1:NSPoint(x:100,y:650),controlPoint2:NSPoint(x:560,y:790));leaf.curve(to:NSPoint(x:310,y:280),controlPoint1:NSPoint(x:800,y:360),controlPoint2:NSPoint(x:520,y:200));leaf.fill()
NSColor(calibratedRed:0.12,green:0.31,blue:0.23,alpha:1).setStroke()
let vein=NSBezierPath();vein.move(to:NSPoint(x:280,y:220));vein.curve(to:NSPoint(x:650,y:650),controlPoint1:NSPoint(x:390,y:450),controlPoint2:NSPoint(x:490,y:530));vein.lineWidth=36;vein.lineCapStyle = .round;vein.stroke()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
