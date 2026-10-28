#!/usr/bin/env swift
// Draws the app icon: a ">_" prompt on a dark tile, the ">" in the same
// orange the Mac uses for Claude's mark.
//
//     swift iOS/scripts/make-icon.swift iOS/TabTermMobile/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// iOS masks the corners itself, so the tile is drawn square and opaque.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024

// No alpha channel: App Store validation rejects an icon that has one, even
// when every pixel is opaque.
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.13, green: 0.135, blue: 0.16, alpha: 1),
    ending: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.045, alpha: 1)
)!
gradient.draw(in: bounds, angle: -90)

// A faint inner frame, like a terminal window's edge.
let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 120, dy: 170), xRadius: 56, yRadius: 56)
NSColor(white: 1, alpha: 0.06).setFill()
frame.fill()
NSColor(white: 1, alpha: 0.10).setStroke()
frame.lineWidth = 6
frame.stroke()

let font = NSFont.monospacedSystemFont(ofSize: 360, weight: .bold)
let prompt = NSMutableAttributedString()
prompt.append(NSAttributedString(string: ">", attributes: [
    .font: font,
    .foregroundColor: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1),
]))
prompt.append(NSAttributedString(string: "_", attributes: [
    .font: font,
    .foregroundColor: NSColor(white: 0.92, alpha: 1),
]))
let textSize = prompt.size()
prompt.draw(at: NSPoint(x: (CGFloat(size) - textSize.width) / 2, y: (CGFloat(size) - textSize.height) / 2 + 10))

NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("no png") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
print("wrote \(output)")
