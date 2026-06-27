// Citadel — Core Text rasteriser with caching.
//
// The HUD, title, menus and score screens all draw through here: arbitrary
// strings rendered through Core Text into small premultiplied-RGBA bitmaps and
// composited over the framebuffer (which is then upscaled, so the anti-aliased
// edges read as crisp retro text rather than the blocky 5×7 grid). Results are
// cached by (string, size, weight, colour) so per-frame HUD text is free after
// the first frame. Any Unicode works — accents, CJK, emoji — for player names.

import Foundation
import AppKit
import CoreGraphics
import CoreText

enum TextImage {
    struct Bitmap { let pixels: [UInt32]; let w: Int; let h: Int }

    private static var cache: [String: Bitmap] = [:]
    private static var order: [String] = []
    private static let cap = 384

    /// Cached rasterisation. Colour is packed RGBA (alpha ignored).
    static func cached(_ string: String, size: CGFloat, weight: NSFont.Weight, color: UInt32, mono: Bool = false) -> Bitmap? {
        if string.isEmpty { return nil }
        let key = "\(string)|\(Int(size))|\(Int(weight.rawValue * 100))|\(color & 0xFFFFFF)|\(mono ? 1 : 0)"
        if let b = cache[key] { return b }
        guard let b = rasterize(string, fontSize: size, weight: weight, mono: mono,
                                r: CGFloat(redOf(color)) / 255, g: CGFloat(greenOf(color)) / 255,
                                b: CGFloat(blueOf(color)) / 255) else { return nil }
        cache[key] = b
        order.append(key)
        if order.count > cap { let k = order.removeFirst(); cache[k] = nil }
        return b
    }

    /// Rasterise `string` at `fontSize`/`weight` in the given colour. Pixels are
    /// packed RGBA with PREMULTIPLIED colour (composite with out = src+dst*(1-a)),
    /// already in our top-down framebuffer orientation.
    static func rasterize(_ string: String, fontSize: CGFloat, weight: NSFont.Weight = .regular,
                          mono: Bool = false, r: CGFloat, g: CGFloat, b: CGFloat) -> Bitmap? {
        if string.isEmpty { return nil }
        let ns = mono ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
                      : NSFont.systemFont(ofSize: fontSize, weight: weight)
        let font = ns as CTFont
        let color = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let cfAttr = CFAttributedStringCreate(kCFAllocatorDefault, string as CFString, attrs as CFDictionary)
        else { return nil }
        let line = CTLineCreateWithAttributedString(cfAttr)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let widthD = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let w = max(1, Int(widthD.rounded(.up)) + 2)
        let h = max(1, Int((ascent + descent).rounded(.up)) + 2)

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info),
              let data = ctx.data else { return nil }
        ctx.textPosition = CGPoint(x: 1, y: descent + 1)
        CTLineDraw(line, ctx)

        let src = data.bindMemory(to: UInt32.self, capacity: w * h)
        let out = Array(UnsafeBufferPointer(start: src, count: w * h))
        return Bitmap(pixels: out, w: w, h: h)
    }
}
