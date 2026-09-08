#!/usr/bin/swift
//
// Renders the Lucid app icon: a warm coffee-brown squircle with the same
// "cup.and.saucer.fill" glyph used for the menu bar icon. Run via
// generate_icon.sh, which also builds the .iconset/.icns from the output.
//
// Usage: swift generate_icon.swift <output.png> [size]

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: generate_icon.swift <output.png> [size]\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = arguments[1]
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024
let sizeF = CGFloat(size)

guard let rep = NSBitmapImageRep(
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
) else {
    fatalError("Could not create bitmap rep")
}
rep.size = NSSize(width: sizeF, height: sizeF)

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create graphics context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// MARK: - Background squircle

// Apple's Big Sur-style icon shape: a rounded rect whose corner radius is
// ~18% of the canvas, which reads as a "squircle" at icon sizes.
let cornerRadius = sizeF * 0.1811
let backgroundRect = NSRect(x: 0, y: 0, width: sizeF, height: sizeF)
let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius)

let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.89, green: 0.65, blue: 0.38, alpha: 1.0), // warm caramel
    NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.11, alpha: 1.0), // coffee brown
    NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.06, alpha: 1.0)  // dark roast
])!
backgroundGradient.draw(in: backgroundPath, angle: -60)

// Subtle glass-like sheen for depth. Spans the full canvas with soft
// fade-outs at both ends so no hard edge is visible (a sheen clipped to
// a sub-rect would leave a visible seam at its boundary).
backgroundPath.setClip()
if let sheen = NSGradient(
    colors: [
        NSColor(white: 1.0, alpha: 0.0),
        NSColor(white: 1.0, alpha: 0.20),
        NSColor(white: 1.0, alpha: 0.0)
    ],
    atLocations: [0.0, 0.72, 1.0],
    colorSpace: .deviceRGB
) {
    sheen.draw(in: backgroundRect, angle: 90)
}

// MARK: - Coffee cup glyph (same symbol as the menu bar icon)

func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    rect.fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

let symbolConfig = NSImage.SymbolConfiguration(pointSize: sizeF * 0.44, weight: .medium)
guard let baseSymbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil),
      let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) else {
    fatalError("Could not load cup.and.saucer.fill symbol")
}

let cream = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1.0)
let symbolImage = tinted(symbol, color: cream)
let symbolSize = symbolImage.size
let symbolRect = NSRect(
    x: (sizeF - symbolSize.width) / 2,
    y: (sizeF - symbolSize.height) / 2 - sizeF * 0.01,
    width: symbolSize.width,
    height: symbolSize.height
)
symbolImage.draw(in: symbolRect)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(size)x\(size))")
