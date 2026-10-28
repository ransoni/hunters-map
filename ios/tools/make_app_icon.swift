// Draws the app icon (1024×1024 PNG) into the AppIcon asset set:
//   swift ios/tools/make_app_icon.swift
// A hill's contour lines on forest green with a blaze-orange location pin: the map, the
// terrain and the hunter on it. Light, dark and tinted (iOS 18) variants.
import AppKit

let size: CGFloat = 1024
let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../HuntersMap/Assets.xcassets/AppIcon.appiconset").standardized

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

struct Palette {
    var background: (CGColor, CGColor)? // top, bottom; nil = transparent (dark/tinted icons)
    var contour: CGColor
    var indexContour: CGColor
    var pin: CGColor
    var pinCenter: CGColor
}

/// A closed contour: an ellipse whose radius wobbles a little, like real terrain.
func contour(center c: CGPoint, rx: CGFloat, ry: CGFloat, wobble: [(k: CGFloat, amp: CGFloat, phase: CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let r = 1 + wobble.reduce(0) { $0 + $1.amp * sin($1.k * t + $1.phase) }
        let p = CGPoint(x: c.x + rx * r * cos(t), y: c.y + ry * r * sin(t))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func draw(_ palette: Palette, to name: String) throws {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: palette.background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                              : CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Core Graphics has y up; flip so the drawing reads top-down.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    if let (top, bottom) = palette.background {
        let gradient = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
    }

    // The hill: nested contours around a summit right of centre, the outer ones running off
    // the edges like on a map sheet. Every fifth line is an index contour, drawn heavier.
    let summit = CGPoint(x: 590, y: 560)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for i in 0..<9 {
        let step = CGFloat(i)
        let rx = 70 + step * 78, ry = 52 + step * 62
        let wobble: [(k: CGFloat, amp: CGFloat, phase: CGFloat)] = [
            (2, 0.05 + step * 0.006, 0.8), (3, 0.04, 1.9 + step * 0.25), (5, 0.015, step * 0.7),
        ]
        let path = contour(center: CGPoint(x: summit.x - step * 14, y: summit.y + step * 10),
                           rx: rx, ry: ry, wobble: wobble)
        let index = i == 3 || i == 7
        ctx.setStrokeColor(index ? palette.indexContour : palette.contour)
        ctx.setLineWidth(index ? 15 : 8)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // The pin, standing on the summit: a teardrop with its point on the hilltop.
    let tip = CGPoint(x: summit.x - 6, y: summit.y + 18)
    let headCenter = CGPoint(x: tip.x, y: tip.y - 250)
    let headRadius: CGFloat = 150
    let pin = CGMutablePath()
    let spread: CGFloat = 0.62 // where the sides leave the head, in radians from straight down
    pin.move(to: tip)
    pin.addLine(to: CGPoint(x: headCenter.x - headRadius * sin(spread), y: headCenter.y + headRadius * cos(spread)))
    pin.addArc(center: headCenter, radius: headRadius, startAngle: .pi / 2 + spread,
               endAngle: .pi / 2 - spread + 2 * .pi, clockwise: false)
    pin.closeSubpath()

    // A soft shadow lifts the pin off the map.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x000000, 0.35))
    ctx.setFillColor(palette.pin)
    ctx.addPath(pin)
    ctx.fillPath()
    ctx.restoreGState()

    // A transparent centre is cut out of the pin rather than painted over it.
    if palette.pinCenter.alpha == 0 { ctx.setBlendMode(.clear) }
    ctx.setFillColor(palette.pinCenter)
    ctx.fillEllipse(in: CGRect(x: headCenter.x - 62, y: headCenter.y - 62, width: 124, height: 124))

    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    print("wrote", url.path)
}

let orange = rgb(0xE8430C)
try draw(Palette(background: (rgb(0x2F5B3E), rgb(0x1B3A28)), contour: rgb(0xE9DFC4, 0.55),
                 indexContour: rgb(0xE9DFC4, 0.8), pin: orange, pinCenter: rgb(0xFFFFFF)),
         to: "AppIcon.png")
try draw(Palette(background: nil, contour: rgb(0x7FA88A, 0.55), indexContour: rgb(0x7FA88A, 0.85),
                 pin: rgb(0xFF5A1F), pinCenter: rgb(0x10241A)),
         to: "AppIcon-Dark.png")
try draw(Palette(background: nil, contour: rgb(0xFFFFFF, 0.45), indexContour: rgb(0xFFFFFF, 0.75),
                 pin: rgb(0xFFFFFF), pinCenter: rgb(0x000000, 0)),
         to: "AppIcon-Tinted.png")
