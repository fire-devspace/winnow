#!/usr/bin/env swift
// Generates a 1024x1024 app icon: Bitcoin-orange rounded square, black ₿ glyph.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let s = CGSize(width: size, height: size)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Full-bleed orange square (iOS applies its own mask; no rounded corners needed).
ctx.setFillColor(CGColor(red: 0.969, green: 0.576, blue: 0.102, alpha: 1)) // #F7931A
ctx.fill(CGRect(origin: .zero, size: s))

// ₿ glyph, centered, ~62% of icon height.
let glyph = "\u{20BF}"
let fontSize: CGFloat = 640
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor(red: 0.043, green: 0.051, blue: 0.063, alpha: 1), // #0B0D10
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attrs as [NSAttributedString.Key: Any]))
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
                           y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, ctx)

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out)")
