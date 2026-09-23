#!/usr/bin/env swift
// Draws the FieldTap app icon: a flat, minimal signal / radio-wave mark in white on the indigo brand accent
// (#4F46E5), echoing the app's `antenna.radiowaves.left.and.right` motif — a centre emitter with waves
// radiating left and right. No text; legible at 40 px. Reproducible: rerun to regenerate AppIcon.png.
//
//   swift ios/scripts/make-app-icon.swift [OUTPUT.png]
//
// Uses only CoreGraphics + ImageIO (no AppKit), so it runs headless on macOS.

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create context")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}

let w = CGFloat(size)
let c = CGPoint(x: w / 2, y: w / 2)

// Background: a soft vertical indigo gradient (brand accent -> a deeper indigo), full bleed. iOS applies the
// rounded-rect mask itself, so a flat square is correct for a modern single-1024 icon.
let top = rgb(0x63, 0x5B, 0xFF)      // a touch brighter than the accent, for depth at the top
let bottom = rgb(0x3B, 0x34, 0xC4)   // indigo-700, deeper at the base
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: w), end: CGPoint(x: 0, y: 0), options: [])

// The mark: a centre emitter dot plus two concentric wave arcs on each side, opening outward — the
// antenna.radiowaves.left.and.right silhouette, centred and balanced.
ctx.setLineCap(.round)
let white = rgb(255, 255, 255)

// Centre dot.
let dotR: CGFloat = 70
ctx.setFillColor(white)
ctx.addEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))
ctx.fillPath()

// Wave arcs. Two radii per side; the inner wave is heavier, the outer lighter, for a flat sense of distance.
let radii: [CGFloat] = [190, 320]
let widths: [CGFloat] = [70, 62]
let alphas: [Double] = [1.0, 0.72]
// Half-angle of each open arc (degrees) — a touch under a quarter turn so the gap top and bottom stays clean.
let half: CGFloat = 52 * .pi / 180

for (i, r) in radii.enumerated() {
    ctx.setLineWidth(widths[i])
    ctx.setStrokeColor(rgb(255, 255, 255, alphas[i]))
    // Right side: centred on 0 rad.
    ctx.addArc(center: c, radius: r, startAngle: -half, endAngle: half, clockwise: false)
    ctx.strokePath()
    // Left side: centred on pi.
    ctx.addArc(center: c, radius: r, startAngle: .pi - half, endAngle: .pi + half, clockwise: false)
    ctx.strokePath()
}

guard let image = ctx.makeImage() else { fatalError("could not render image") }
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not open \(out) for writing")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
print("wrote \(out) (\(size)x\(size))")
