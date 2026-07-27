#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: generate-app-icon.swift <output.iconset> [preview.png]\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let previewURL = CommandLine.arguments.count >= 3
    ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
try FileManager.default.createDirectory(
    at: iconsetURL, withIntermediateDirectories: true)

func roundedRect(
    _ rect: CGRect,
    radius: CGFloat,
    fill: NSColor,
    stroke: NSColor? = nil,
    lineWidth: CGFloat = 1
) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func drawIcon(in context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }

    let outer = CGRect(x: 64, y: 64, width: 896, height: 896)
    let outerPath = NSBezierPath(roundedRect: outer, xRadius: 205, yRadius: 205)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.24, alpha: 1),
        ending: NSColor(calibratedRed: 0.015, green: 0.03, blue: 0.07, alpha: 1))!
    gradient.draw(in: outerPath, angle: -90)
    NSColor(calibratedRed: 0.14, green: 0.76, blue: 0.95, alpha: 0.8).setStroke()
    outerPath.lineWidth = 18
    outerPath.stroke()

    // LCD bezel.
    roundedRect(
        CGRect(x: 150, y: 275, width: 724, height: 426),
        radius: 72,
        fill: NSColor(calibratedWhite: 0.025, alpha: 1),
        stroke: NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.98, alpha: 1),
        lineWidth: 18)
    roundedRect(
        CGRect(x: 184, y: 309, width: 656, height: 358),
        radius: 42,
        fill: NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.09, alpha: 1))

    // Compact system cards on the left.
    let cyan = NSColor(calibratedRed: 0.17, green: 0.84, blue: 0.98, alpha: 1)
    let green = NSColor(calibratedRed: 0.25, green: 0.91, blue: 0.61, alpha: 1)
    let orange = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    roundedRect(CGRect(x: 212, y: 503, width: 180, height: 130), radius: 24,
                fill: NSColor(calibratedWhite: 0.08, alpha: 1))
    roundedRect(CGRect(x: 212, y: 342, width: 180, height: 130), radius: 24,
                fill: NSColor(calibratedWhite: 0.08, alpha: 1))

    for (index, height) in [54.0, 88.0, 69.0, 104.0].enumerated() {
        roundedRect(
            CGRect(x: 235 + CGFloat(index) * 35, y: 525, width: 20, height: height),
            radius: 10,
            fill: index < 2 ? cyan : green)
    }
    for (index, width) in [128.0, 92.0, 145.0].enumerated() {
        roundedRect(
            CGRect(x: 231, y: 424 - CGFloat(index) * 34, width: width, height: 14),
            radius: 7,
            fill: index == 0 ? orange : cyan)
    }

    // Two AI agent columns.
    roundedRect(CGRect(x: 424, y: 342, width: 181, height: 291), radius: 28,
                fill: NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.20, alpha: 1),
                stroke: cyan.withAlphaComponent(0.65), lineWidth: 8)
    roundedRect(CGRect(x: 625, y: 342, width: 181, height: 291), radius: 28,
                fill: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.21, alpha: 1),
                stroke: green.withAlphaComponent(0.65), lineWidth: 8)

    for x in [448.0, 649.0] {
        roundedRect(CGRect(x: x, y: 577, width: 86, height: 18), radius: 9, fill: cyan)
        roundedRect(CGRect(x: x, y: 534, width: 128, height: 12), radius: 6,
                    fill: NSColor(calibratedWhite: 0.62, alpha: 1))
        roundedRect(CGRect(x: x, y: 504, width: 105, height: 12), radius: 6,
                    fill: NSColor(calibratedWhite: 0.42, alpha: 1))
        roundedRect(CGRect(x: x, y: 405, width: 132, height: 18), radius: 9,
                    fill: green.withAlphaComponent(0.8))
    }

    // Status LED and monitor stand.
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: CGRect(x: 785, y: 296, width: 30, height: 30)).fill()
    roundedRect(CGRect(x: 468, y: 208, width: 88, height: 84), radius: 24,
                fill: NSColor(calibratedWhite: 0.18, alpha: 1))
    roundedRect(CGRect(x: 360, y: 172, width: 304, height: 54), radius: 27,
                fill: NSColor(calibratedWhite: 0.22, alpha: 1))
}

func pngData(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, size) in outputs {
    try pngData(size: size).write(to: iconsetURL.appendingPathComponent(filename))
}
if let previewURL {
    try pngData(size: 512).write(to: previewURL)
}
