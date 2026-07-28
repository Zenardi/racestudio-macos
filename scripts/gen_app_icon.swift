#!/usr/bin/env swift
//
// Draws the RaceStudio macOS app icon at a given pixel size and writes a PNG.
// Pure offscreen AppKit/Core Graphics — no Xcode, no network, no image assets —
// so the icon is fully reproducible from source (run via scripts/gen_app_icon.sh).
//
// Design (per docs/BRAND.md, issue 7.4): a brand-red rounded-rect "squircle"
// (accent #C21A2B family) carrying a single white racing line through an apex
// with a telemetry node — the brand's motorsport-red accent used exactly as the
// guide describes ("racing line"), high-contrast white-on-red, legible at 16 px.
//
// Usage: swift gen_app_icon.swift <pixels> <out.png>

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let pixels = Int(arguments[1]), pixels > 0 else {
    FileHandle.standardError.write(Data("usage: gen_app_icon.swift <pixels> <out.png>\n".utf8))
    exit(2)
}
let outputPath = arguments[2]
let dimension = CGFloat(pixels)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("error: could not create bitmap context\n".utf8))
    exit(1)
}
rep.size = NSSize(width: dimension, height: dimension)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

// The rounded-rect field, inset a touch so the baked shadow has room to breathe.
let inset = 0.086 * dimension
let side = dimension - inset * 2
let corner = 0.2237 * side   // macOS squircle corner ratio
let field = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                         xRadius: corner, yRadius: corner)

// Soft drop shadow, cast by a solid fill before the gradient is painted over it.
let shadow = NSShadow()
shadow.shadowBlurRadius = 0.035 * dimension
shadow.shadowOffset = NSSize(width: 0, height: -0.010 * dimension)
shadow.shadowColor = NSColor(deviceWhite: 0, alpha: 0.30)
NSGraphicsContext.saveGraphicsState()
shadow.set()
srgb(180, 20, 36).setFill()
field.fill()
NSGraphicsContext.restoreGraphicsState()

// Brand-red vertical gradient (lighter top → deeper bottom).
if let gradient = NSGradient(colors: [srgb(206, 36, 54), srgb(156, 21, 35)]) {
    gradient.draw(in: field, angle: -90)
}

// A faint top sheen for depth, clipped to the field.
NSGraphicsContext.saveGraphicsState()
field.addClip()
if let sheen = NSGradient(colors: [NSColor(deviceWhite: 1, alpha: 0.14), NSColor(deviceWhite: 1, alpha: 0)]) {
    sheen.draw(in: NSRect(x: inset, y: 0.55 * dimension, width: side, height: 0.45 * dimension), angle: -90)
}
NSGraphicsContext.restoreGraphicsState()

// The white racing line: a smooth apex through a corner (AppKit y is up).
let apex = NSPoint(x: 0.50 * dimension, y: 0.30 * dimension)
let line = NSBezierPath()
line.lineWidth = 0.115 * dimension
line.lineCapStyle = .round
line.lineJoinStyle = .round
line.move(to: NSPoint(x: 0.22 * dimension, y: 0.70 * dimension))
line.curve(to: apex,
           controlPoint1: NSPoint(x: 0.30 * dimension, y: 0.44 * dimension),
           controlPoint2: NSPoint(x: 0.40 * dimension, y: 0.30 * dimension))
line.curve(to: NSPoint(x: 0.80 * dimension, y: 0.66 * dimension),
           controlPoint1: NSPoint(x: 0.62 * dimension, y: 0.30 * dimension),
           controlPoint2: NSPoint(x: 0.70 * dimension, y: 0.46 * dimension))
NSColor(deviceWhite: 1, alpha: 0.97).setStroke()
line.stroke()

// The apex node — a white marker with a red core (a telemetry cursor at the apex).
func disc(_ center: NSPoint, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)).fill()
}
disc(apex, 0.088 * dimension, NSColor(deviceWhite: 1, alpha: 1))
disc(apex, 0.040 * dimension, srgb(156, 21, 35))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
