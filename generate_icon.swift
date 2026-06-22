#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Generates AppIcon.icns for Citadel — the Jorvik visual language (brand-blue
// rounded-square badge + faint wireframe globe backdrop, shared with Strataris)
// with a white CITADEL glyph over the world: an occupied fortress with a red
// breach light. A world held, waiting to be retaken.
//
// Run:  swift generate_icon.swift   (emits AppIcon.icns at project root;
// release.mk `build` copies it into Contents/Resources).

let brandBlue = NSColor(red: 0x00 / 255.0, green: 0x40 / 255.0, blue: 0x80 / 255.0, alpha: 1.0)

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let pts = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { pts.deallocate() }
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

func drawIcon(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    let cx = s / 2, cy = s / 2
    let gradSpace = CGColorSpaceCreateDeviceRGB()

    // background badge
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill(); bgPath.fill()
    if let g = CGGradient(colorsSpace: gradSpace, colors: [
        NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 0, alpha: 0.14).cgColor] as CFArray, locations: [0, 1]) {
        ctx.saveGState(); ctx.addPath(bgPath.cgPath); ctx.clip()
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy + s * 0.12), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: s * 0.6, options: [])
        ctx.restoreGState()
    }

    // faint globe backdrop
    ctx.saveGState(); ctx.addPath(bgPath.cgPath); ctx.clip()
    let gr = s * 0.34
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor); ctx.setLineWidth(s * 0.008)
    ctx.strokeEllipse(in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(s * 0.005)
    for i in 1...3 {
        let eW = gr * CGFloat(i) / 4
        ctx.strokeEllipse(in: CGRect(x: cx - eW, y: cy - gr, width: eW * 2, height: gr * 2))
    }
    ctx.beginPath(); ctx.move(to: CGPoint(x: cx - gr, y: cy)); ctx.addLine(to: CGPoint(x: cx + gr, y: cy)); ctx.strokePath()
    ctx.restoreGState()

    // citadel glyph (units in a 22-wide space)
    ctx.saveGState(); ctx.addPath(bgPath.cgPath); ctx.clip()
    let u = s / 22.0
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
        c.setFill(); NSBezierPath(rect: NSRect(x: cx + (x - 11) * u, y: cy + (y - 11) * u, width: w * u, height: h * u)).fill()
    }
    // drop shadow pass
    let white = NSColor.white, shadow = NSColor(white: 0, alpha: 0.25)
    for pass in 0..<2 {
        let c = pass == 0 ? shadow : white
        let oy: CGFloat = pass == 0 ? -0.4 : 0
        // side towers
        rect(4, 5 + oy, 4, 9, c); rect(14, 5 + oy, 4, 9, c)
        // central keep (taller)
        rect(8.5, 5 + oy, 5, 12, c)
        // crenellations
        for bx in [4.0, 6.0] { rect(CGFloat(bx), 13.6 + oy, 1.4, 1.6, c) }
        for bx in [14.0, 16.0] { rect(CGFloat(bx), 13.6 + oy, 1.4, 1.6, c) }
        for bx in [8.5, 10.4, 12.3] { rect(CGFloat(bx), 16.6 + oy, 1.4, 1.8, c) }
    }
    // dark gate + red breach light
    rect(9.6, 5, 2.8, 4.5, NSColor(white: 0.0, alpha: 0.55))
    NSColor(red: 1, green: 0.3, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 1.0 * u, y: cy + 0.2 * u, width: 2 * u, height: 2 * u)).fill()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
let iconsetDir = "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
for (size, name) in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
try! task.run(); task.waitUntilExit()
try? fm.removeItem(atPath: iconsetDir)
print("Generated AppIcon.icns")
