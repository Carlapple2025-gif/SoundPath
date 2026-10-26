import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make_icon <output.png>\n".utf8))
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.setAllowsAntialiasing(true)

let canvas = CGFloat(size)
let rect = NSRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)
let rounded = NSBezierPath(roundedRect: rect, xRadius: 235, yRadius: 235)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.75, blue: 0.80, alpha: 1)
])!
gradient.draw(in: rounded, angle: -55)

NSColor.white.withAlphaComponent(0.14).setStroke()
rounded.lineWidth = 6
rounded.stroke()

let configuration = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

if let symbol = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let symbolSize = symbol.size
    let scale = min(540 / max(symbolSize.width, 1), 540 / max(symbolSize.height, 1))
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let drawRect = NSRect(
        x: (canvas - drawSize.width) / 2,
        y: (canvas - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    symbol.draw(in: drawRect)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
