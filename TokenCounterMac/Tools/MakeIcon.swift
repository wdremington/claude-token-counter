// Draws the app icon as an .iconset. Run via `swift Tools/MakeIcon.swift <outdir>`.
// Kept as a build-time script so no binary assets live in the repo.

import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./TokenCounter.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Bars use the same categorical hues as the charts: blue, aqua, orange.
let barColors: [(CGFloat, CGFloat, CGFloat)] = [
    (0x2a / 255, 0x78 / 255, 0xd6 / 255),
    (0x1b / 255, 0xaf / 255, 0x7a / 255),
    (0xeb / 255, 0x68 / 255, 0x34 / 255),
]

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high

    // macOS app icons sit inset inside their canvas.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    let backdrop = [
        CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: backdrop, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    let heights: [CGFloat] = [0.30, 0.50, 0.72]
    let barWidth = rect.width * 0.155
    let gap = rect.width * 0.078
    let totalWidth = barWidth * 3 + gap * 2
    let startX = rect.midX - totalWidth / 2
    let baseY = rect.minY + rect.height * 0.19

    for i in 0..<3 {
        let bar = CGRect(
            x: startX + CGFloat(i) * (barWidth + gap),
            y: baseY,
            width: barWidth,
            height: rect.height * heights[i]
        )
        let c = barColors[i]
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        let corner = barWidth * 0.3
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.fillPath()
    }

    ctx.restoreGState()
    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = render(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: "\(outDir)/\(variant.name).png")
}

print("wrote \(variants.count) icon variants to \(outDir)")
