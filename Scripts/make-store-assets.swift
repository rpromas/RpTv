#!/usr/bin/env swift
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Draws the App Store creative assets: the product page header (3840 × 1646) and the search results asset
// (3840 × 2560), as in Apple's templates (developer.apple.com/app-store/asset-best-practices). What matters is
// kept inside each template's centred art safe area. The search asset shows iPhone screenshots, so run
// Scripts/screenshots.sh first.
//
//     Scripts/make-store-assets.swift [output directory, default build/store-assets]

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appending(path: "build/store-assets")
let screenshots = root.appending(path: "build/screenshots/iPhone 17 Pro Max")
let icon = NSImage(contentsOf: root.appending(path: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let brand = rgb(0x17A361)
let deep = rgb(0x041A10)
let night = rgb(0x020906)

/// Renders into an opaque sRGB bitmap (App Store Connect rejects transparency) and saves it as PNG.
func render(_ name: String, width: Int, height: Int, draw: (CGRect) -> Void) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, like the templates.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let url = output.appending(path: "\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print(url.path)
}

/// The dark green field both assets share, brighter towards `glow`.
func background(_ rect: CGRect, glow: CGPoint) {
    night.setFill()
    rect.fill()
    let radial = NSGradient(colors: [rgb(0x0B5132), deep, night], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    radial.draw(fromCenter: glow, radius: 0, toCenter: glow, radius: rect.width * 0.62, options: [])
}

/// A deterministic stream of numbers in 0..<1, so every run draws the same pattern.
struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
}

/// Rows of rounded programme blocks, like the app's guide grid, fading out around `clear` so text stays legible.
func guidePattern(_ rect: CGRect, clear: CGRect) {
    var random = Random(state: 7)
    let rowHeight: CGFloat = 132, gap: CGFloat = 18
    // Right of the safe area, so it never crosses the text.
    let nowX = clear.maxX + 260
    var y = rect.minY - 40
    while y < rect.maxY {
        var x = rect.minX - random.next() * 400
        while x < rect.maxX {
            let width = 260 + random.next() * 620
            let block = CGRect(x: x, y: y, width: width - gap, height: rowHeight)
            let onAir = block.minX < nowX && block.maxX > nowX
            // Fainter near the middle, where the text sits.
            let dx = max(0, abs(block.midX - clear.midX) - clear.width / 2) / (rect.width / 2)
            let dy = max(0, abs(block.midY - clear.midY) - clear.height / 2) / (rect.height / 2)
            let distance = min(1, (dx * dx + dy * dy).squareRoot() * 2.2)
            let alpha = (onAir ? 0.30 : 0.05 + random.next() * 0.09) * (0.1 + 0.9 * distance)
            (onAir ? brand : rgb(0x2FD38A)).withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: block, xRadius: 28, yRadius: 28).fill()
            x += width
        }
        y += rowHeight + gap
    }
    // The "now" line.
    rgb(0x2FD38A, 0.22).setFill()
    CGRect(x: nowX - 3, y: rect.minY, width: 6, height: rect.height).fill()
}

func drawIcon(in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = rect.width * 0.12
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.04)
    shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    brand.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

@discardableResult
func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          width: CGFloat = 4000, lineSpacing: CGFloat = 0) -> CGSize {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        .kern: -size * 0.01,
    ])
    let bounds = attributed.boundingRect(with: CGSize(width: width, height: 4000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
    attributed.draw(with: CGRect(origin: point, size: bounds.size), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return bounds.size
}

/// A screenshot as a phone: rounded screen in a thin dark frame, with a soft shadow.
func phone(_ name: String, height: CGFloat, at origin: CGPoint) {
    guard let image = NSImage(contentsOf: screenshots.appending(path: "\(name).png")) else {
        fatalError("No \(name).png in \(screenshots.path). Run Scripts/screenshots.sh first.")
    }
    let width = height * image.size.width / image.size.height
    let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
    let bezel = width * 0.035
    let radius = width * 0.15
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = 90
    shadow.shadowOffset = NSSize(width: 0, height: -30)
    shadow.set()
    rgb(0x0E0F10).setFill()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(0x3A3D40).setStroke()
    let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
    edge.lineWidth = 4
    edge.stroke()
    let screen = frame.insetBy(dx: bezel, dy: bezel)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: radius - bezel, yRadius: radius - bezel).addClip()
    image.draw(in: screen, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Product page header

// Template: 3840 × 1646, art safe area 1646 × 661 at (1097, 493).
try render("header", width: 3840, height: 1646) { rect in
    let safe = CGRect(x: 1097, y: 493, width: 1646, height: 661)
    background(rect, glow: CGPoint(x: safe.midX, y: safe.midY))
    guidePattern(rect, clear: safe.insetBy(dx: -40, dy: -10))
    let iconSize: CGFloat = 400
    drawIcon(in: CGRect(x: safe.minX + 30, y: safe.midY - iconSize / 2, width: iconSize, height: iconSize))
    let textX = safe.minX + 30 + iconSize + 90
    text("RpTv", at: CGPoint(x: textX, y: safe.midY - 225), size: 250, weight: .heavy, color: .white)
    text("Bring your own playlist.", at: CGPoint(x: textX + 8, y: safe.midY + 70), size: 96, weight: .semibold,
         color: rgb(0x8FE8BC))
}

// MARK: - Search results

// Template: 3840 × 2560, art safe area 2168 × 1030 at (836, 765).
try render("search-results", width: 3840, height: 2560) { rect in
    let safe = CGRect(x: 836, y: 765, width: 2168, height: 1030)
    background(rect, glow: CGPoint(x: safe.midX + 300, y: safe.midY))
    guidePattern(rect, clear: safe.insetBy(dx: -60, dy: -60))
    // Text on the left half of the safe area, two phones on the right.
    let iconSize: CGFloat = 190
    drawIcon(in: CGRect(x: safe.minX + 20, y: safe.minY + 70, width: iconSize, height: iconSize))
    text("RpTv", at: CGPoint(x: safe.minX + 20 + iconSize + 50, y: safe.minY + 92), size: 128, weight: .heavy,
         color: .white)
    text("Live TV, guide,\nmovies and series", at: CGPoint(x: safe.minX + 20, y: safe.minY + 340), size: 128,
         weight: .bold, color: .white, width: 1150, lineSpacing: 6)
    text("From the IPTV playlists\nyou already have.", at: CGPoint(x: safe.minX + 24, y: safe.minY + 712),
         size: 80, weight: .semibold, color: rgb(0x8FE8BC), width: 1150, lineSpacing: 8)
    let phoneHeight = safe.height
    let phoneWidth = phoneHeight * 1320 / 2868
    phone("1 Live TV", height: phoneHeight, at: CGPoint(x: safe.maxX - 2 * phoneWidth - 60, y: safe.minY))
    phone("4 Movies", height: phoneHeight, at: CGPoint(x: safe.maxX - phoneWidth, y: safe.minY))
}
