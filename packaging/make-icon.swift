// Renders the Helipad app icon: dark asphalt squircle, white landing ring,
// bold H, orange beacon dots. Run: swift packaging/make-icon.swift <out.png>
import AppKit
import CoreText

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// macOS icon grid: content square ~832pt centered in 1024 canvas
let inset: CGFloat = 96
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

// asphalt background with a subtle vertical gradient
ctx.addPath(squircle)
ctx.clip()
let bgColors = [
    CGColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 1),
    CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: nil, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: size / 2, y: size), end: CGPoint(x: size / 2, y: 0), options: [])

let center = CGPoint(x: size / 2, y: size / 2)

// landing ring
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.setLineWidth(34)
let ringRadius: CGFloat = 300
ctx.strokeEllipse(in: CGRect(
    x: center.x - ringRadius, y: center.y - ringRadius,
    width: ringRadius * 2, height: ringRadius * 2
))

// orange beacon dots at the four corners of the pad, outside the ring
ctx.setFillColor(CGColor(red: 0.91, green: 0.57, blue: 0.36, alpha: 1))
let beaconOffset: CGFloat = 368
let beaconRadius: CGFloat = 22
for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
    let x = center.x + beaconOffset * dx * 0.7071
    let y = center.y + beaconOffset * dy * 0.7071
    ctx.fillEllipse(in: CGRect(x: x - beaconRadius, y: y - beaconRadius, width: beaconRadius * 2, height: beaconRadius * 2))
}

// the H
let font = NSFont(name: "HelveticaNeue-Bold", size: 430) ?? NSFont.boldSystemFont(ofSize: 430)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "H", attributes: attrs))
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(
    x: center.x - bounds.midX,
    y: center.y - bounds.midY
)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print(out)
