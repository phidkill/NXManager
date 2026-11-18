import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.dropFirst().first ?? "NativeApp"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.translateBy(x: 0, y: canvas)
context.scaleBy(x: 1, y: -1)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: 1)
}

func roundedRect(_ rect: CGRect, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

let space = CGColorSpaceCreateDeviceRGB()
let backgroundColors = [color(0.095, 0.15, 0.31), color(0.19, 0.37, 0.74), color(0.31, 0.72, 0.66)] as CFArray
let background = CGGradient(colorsSpace: space, colors: backgroundColors, locations: [0, 0.56, 1])!
context.drawLinearGradient(background, start: CGPoint(x: -300, y: -300), end: CGPoint(x: 1324, y: 1324),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// A quiet lower wave adds depth while leaving the silhouette crisp at small sizes.
context.saveGState()
context.setAlpha(0.055)
context.setFillColor(color(1, 1, 1))
let wave = CGMutablePath()
wave.move(to: CGPoint(x: 0, y: 790))
wave.addCurve(to: CGPoint(x: 520, y: 800), control1: CGPoint(x: 190, y: 700), control2: CGPoint(x: 310, y: 890))
wave.addCurve(to: CGPoint(x: 1024, y: 770), control1: CGPoint(x: 710, y: 720), control2: CGPoint(x: 850, y: 700))
wave.addLine(to: CGPoint(x: 1024, y: 1024))
wave.addLine(to: CGPoint(x: 0, y: 1024))
wave.closeSubpath()
context.addPath(wave)
context.fillPath()
context.restoreGState()

roundedRect(CGRect(x: 146, y: 166, width: 732, height: 524), radius: 58, fill: color(0.957, 0.969, 0.996))
let screenColors = [color(0.063, 0.094, 0.176), color(0.125, 0.184, 0.337)] as CFArray
let screenGradient = CGGradient(colorsSpace: space, colors: screenColors, locations: [0, 1])!
let screenPath = CGPath(roundedRect: CGRect(x: 183, y: 203, width: 658, height: 450), cornerWidth: 30, cornerHeight: 30, transform: nil)
context.saveGState()
context.addPath(screenPath)
context.clip()
context.drawLinearGradient(screenGradient, start: CGPoint(x: 183, y: 203), end: CGPoint(x: 841, y: 653), options: [])
context.restoreGState()

let standPath = CGMutablePath()
standPath.move(to: CGPoint(x: 443, y: 690))
standPath.addLine(to: CGPoint(x: 581, y: 690))
standPath.addLine(to: CGPoint(x: 608, y: 810))
standPath.addLine(to: CGPoint(x: 416, y: 810))
standPath.closeSubpath()
context.setFillColor(color(0.906, 0.929, 0.98))
context.addPath(standPath)
context.fillPath()
roundedRect(CGRect(x: 340, y: 796, width: 344, height: 42), radius: 21, fill: color(0.957, 0.969, 0.996))

let controller = CGMutablePath()
controller.move(to: CGPoint(x: 384, y: 372))
controller.addCurve(to: CGPoint(x: 313, y: 439), control1: CGPoint(x: 350, y: 372), control2: CGPoint(x: 326, y: 398))
controller.addLine(to: CGPoint(x: 276, y: 550))
controller.addCurve(to: CGPoint(x: 324, y: 578), control1: CGPoint(x: 265, y: 582), control2: CGPoint(x: 298, y: 602))
controller.addLine(to: CGPoint(x: 376, y: 531))
controller.addLine(to: CGPoint(x: 648, y: 531))
controller.addLine(to: CGPoint(x: 700, y: 578))
controller.addCurve(to: CGPoint(x: 748, y: 550), control1: CGPoint(x: 726, y: 602), control2: CGPoint(x: 759, y: 582))
controller.addLine(to: CGPoint(x: 711, y: 439))
controller.addCurve(to: CGPoint(x: 640, y: 372), control1: CGPoint(x: 698, y: 398), control2: CGPoint(x: 674, y: 372))
controller.closeSubpath()
let controllerColors = [color(1, 1, 1), color(0.85, 0.90, 1)] as CFArray
let controllerGradient = CGGradient(colorsSpace: space, colors: controllerColors, locations: [0, 1])!
context.saveGState()
context.addPath(controller)
context.clip()
context.drawLinearGradient(controllerGradient, start: CGPoint(x: 0, y: 372), end: CGPoint(x: 0, y: 602), options: [])
context.restoreGState()

context.setStrokeColor(color(0.19, 0.37, 0.74))
context.setLineWidth(21)
context.setLineCap(.round)
context.move(to: CGPoint(x: 400, y: 420)); context.addLine(to: CGPoint(x: 400, y: 488))
context.move(to: CGPoint(x: 366, y: 454)); context.addLine(to: CGPoint(x: 434, y: 454))
context.strokePath()
context.setFillColor(color(0.28, 0.75, 0.66))
for point in [CGPoint(x: 637, y: 425), CGPoint(x: 674, y: 462), CGPoint(x: 600, y: 462), CGPoint(x: 637, y: 499)] {
    context.fillEllipse(in: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
}
roundedRect(CGRect(x: 472, y: 285, width: 80, height: 10), radius: 5, fill: color(0.28, 0.75, 0.66))

NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.png")
let pngData = bitmap.representation(using: .png, properties: [:])!
try pngData.write(to: url)
