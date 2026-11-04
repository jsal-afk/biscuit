#!/usr/bin/swift
import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/biscuit.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 214, yRadius: 214).fill()
        NSColor(calibratedRed: 0.88, green: 0.69, blue: 0.41, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 166, y: 166, width: 692, height: 692)).fill()
        NSColor(calibratedRed: 0.96, green: 0.81, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 190, y: 210, width: 644, height: 624)).fill()
        NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.14, alpha: 1).setFill()
        for (x, y, diameter) in [(350, 620, 60), (590, 650, 72), (460, 445, 58), (650, 375, 64), (315, 325, 48)] {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
