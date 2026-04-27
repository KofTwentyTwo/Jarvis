// build-icon.swift — render Jarvis app icon at 1024×1024
// Composes the menu-bar arc-reactor silhouette atop a radial-gradient backplate
// with a subtle inner glow, evoking the Iron Man HUD palette.
//
// Usage:
//   swift build-icon.swift <silhouette.png> <output.png>

import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 3 else {
    fputs("usage: build-icon.swift <silhouette.png> <output.png>\n", stderr)
    exit(2)
}

let silhouettePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let silhouetteImage = NSImage(contentsOfFile: silhouettePath),
      let silhouetteCG = silhouetteImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("error: could not load silhouette: \(silhouettePath)\n", stderr)
    exit(1)
}

let size: CGFloat = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)

// macOS 11+ icons use rounded-rect "squircle" shape. The system clips icons
// automatically when displayed in Dock/Finder, but we draw the squircle
// ourselves so the corners are visible during compositing and so dark
// backgrounds show against the system's surrounding chrome correctly.
//
// Per HIG: squircle radius is approximately size * 0.225 = 230.4 at 1024.
let cornerRadius: CGFloat = size * 0.2237

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("error: could not create graphics context\n", stderr)
    exit(1)
}

// Squircle clip path
let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(squircle)
ctx.clip()

// Backplate: radial gradient — bright cyan core to deep navy at edges.
// Iron Man arc-reactor palette: #4FC3F7 (light cyan) → #0D47A1 (deep navy) → #061229 (near-black)
let inner = CGColor(red: 79/255.0, green: 195/255.0, blue: 247/255.0, alpha: 1.0)   // #4FC3F7
let mid   = CGColor(red: 13/255.0, green: 71/255.0,  blue: 161/255.0, alpha: 1.0)   // #0D47A1
let outer = CGColor(red: 6/255.0,  green: 18/255.0,  blue: 41/255.0,  alpha: 1.0)   // #061229
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [inner, mid, outer] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!

let center = CGPoint(x: size / 2, y: size / 2)
ctx.drawRadialGradient(
    gradient,
    startCenter: center, startRadius: 0,
    endCenter: center, endRadius: size * 0.7,
    options: []
)

// Inner glow ring — a subtle bright halo at ~25% radius to evoke the
// "energized" arc-reactor look without overwhelming the silhouette.
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
        CGColor(red: 79/255.0, green: 195/255.0, blue: 247/255.0, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: center, startRadius: 0,
    endCenter: center, endRadius: size * 0.35,
    options: []
)

// Silhouette pass — composite the arc-reactor symbol in white, scaled to
// ~62% of the icon area and centered. The PDF rendered to PNG is black-on-
// transparent; we'll re-draw it as a luminosity mask producing white-on-glow.
let silhouetteSize: CGFloat = size * 0.62
let silhouetteOrigin = CGPoint(x: (size - silhouetteSize) / 2, y: (size - silhouetteSize) / 2)
let silhouetteRect = CGRect(origin: silhouetteOrigin, size: CGSize(width: silhouetteSize, height: silhouetteSize))

// Use the silhouette's alpha as a mask, then fill with bright cyan-white.
ctx.saveGState()
ctx.clip(to: silhouetteRect, mask: silhouetteCG)
ctx.setFillColor(red: 0.95, green: 0.99, blue: 1.0, alpha: 1.0)  // near-white with the faintest cyan tint
ctx.fill(silhouetteRect)
ctx.restoreGState()

// Outer rim — a 1-2px brighter edge along the squircle to give the icon
// definition against any wallpaper.
ctx.addPath(squircle)
ctx.setStrokeColor(red: 79/255.0, green: 195/255.0, blue: 247/255.0, alpha: 0.8)
ctx.setLineWidth(2.5)
ctx.strokePath()

guard let cgImage = ctx.makeImage() else {
    fputs("error: could not finalize image\n", stderr)
    exit(1)
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fputs("error: could not encode PNG\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
do {
    try pngData.write(to: url)
    print("wrote \(outputPath) — \(pngData.count) bytes")
} catch {
    fputs("error: write failed: \(error)\n", stderr)
    exit(1)
}
