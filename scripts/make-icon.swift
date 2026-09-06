// make-icon.swift
// Renders the Vitals app icon offscreen with AppKit/CoreGraphics and packages it
// as Assets/AppIcon.icns. Run from the repo root or anywhere:
//
//     swift scripts/make-icon.swift
//
// Design: Big Sur+ template. A rounded square on a 1024pt canvas, inset 100pt on
// every side (824pt shape, about 10% margin), corner radius 22.37% of the shape
// width. Dark charcoal gradient, one green dot, a subtle white ECG trace under it.
// No text.

import AppKit

let canvas: CGFloat = 1024
let shapeInset: CGFloat = 100
let cornerRatio: CGFloat = 0.2237

let green = CGColor(red: 0.20, green: 0.72, blue: 0.40, alpha: 1)
let charcoalTop = CGColor(red: 0.24, green: 0.25, blue: 0.27, alpha: 1)
let charcoalBottom = CGColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)

/// Draws the icon in canvas coordinates (1024 x 1024, origin bottom-left).
/// `pixelsPerCanvasUnit` lets small sizes keep hairlines visible.
func drawIcon(in ctx: CGContext, pixelsPerCanvasUnit: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: pixelsPerCanvasUnit, y: pixelsPerCanvasUnit)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Background squircle, clipped so the gradient never bleeds past the corners.
    let shape = CGRect(x: shapeInset, y: shapeInset,
                       width: canvas - 2 * shapeInset, height: canvas - 2 * shapeInset)
    let radius = shape.width * cornerRatio
    let squircle = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(squircle)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [charcoalTop, charcoalBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: shape.midX, y: shape.maxY),
                           end: CGPoint(x: shape.midX, y: shape.minY),
                           options: [])

    // ECG trace: flat, one sharp beat, flat. Sits under the dot.
    // Stroke width never drops below ~1.6 device pixels so it survives 16pt.
    let baseline: CGFloat = 352
    let trace: [CGPoint] = [
        CGPoint(x: 272, y: baseline),
        CGPoint(x: 428, y: baseline),
        CGPoint(x: 462, y: baseline),
        CGPoint(x: 488, y: baseline + 76),
        CGPoint(x: 524, y: baseline - 84),
        CGPoint(x: 556, y: baseline),
        CGPoint(x: 600, y: baseline),
        CGPoint(x: 752, y: baseline),
    ]
    let minStroke = 1.6 / pixelsPerCanvasUnit
    ctx.setLineWidth(max(20, minStroke))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    ctx.addLines(between: trace)
    ctx.strokePath()

    // The dot. Crisp edge, no glow, no outline.
    let dotCenter = CGPoint(x: 512, y: 600)
    let dotRadius: CGFloat = 118
    ctx.setFillColor(green)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                               width: dotRadius * 2, height: dotRadius * 2))

    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)   // 1 point == 1 pixel, no retina doubling
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawIcon(in: gc.cgContext, pixelsPerCanvasUnit: CGFloat(pixels) / canvas)
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let srgb = rep.retagging(with: .sRGB) ?? rep
    return srgb.representation(using: .png, properties: [:])!
}

func run(_ tool: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assets = repoRoot.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
let icns = assets.appendingPathComponent("AppIcon.icns")

do {
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    // iconutil wants exactly these names: icon_<pt>x<pt>.png and icon_<pt>x<pt>@2x.png
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
            try renderPNG(pixels: points * scale).write(to: file)
        }
    }

    let status = try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    guard status == 0 else {
        FileHandle.standardError.write("iconutil failed with status \(status)\n".data(using: .utf8)!)
        exit(1)
    }
    try fm.removeItem(at: iconset)
    print("wrote \(icns.path)")
} catch {
    FileHandle.standardError.write("make-icon failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
