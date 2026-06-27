// Citadel — 2D packed-RGBA software canvas.
//
// Everything the player sees lands here first: the raycaster paints walls /
// floors / ceilings / sprites into the framebuffer, the HUD and menus
// composite on top, and Renderer uploads the whole buffer to a Metal texture
// and upscales it nearest-neighbour to the window. A per-column z-buffer holds
// each wall column's perpendicular distance so billboarded sprites occlude
// correctly behind geometry.
//
// Internal resolution is 320×200 — Doom's native mode — for the period-correct
// chunky pixels. The 3-D view occupies the top `viewHeight` rows; the status
// bar owns the bottom `statusBarHeight`.

import Foundation
import AppKit

enum RenderConfig {
    // The UI is authored in a logical 640×400 space (2× Doom's base). The actual
    // framebuffer is that scaled by num/den — ONE knob for the whole game. The
    // 8:5 aspect and 2:1 viewport are preserved at any scale, so FOV/projection
    // are unchanged; you just get more pixels (smoother light, finer detail).
    //   3/2 → 960×600 · 2/1 → 1280×800 · 1/1 → 640×400
    static let num = 2, den = 1
    static let baseWidth = 640, baseHeight = 400, baseStatusBar = 80
    static let width = baseWidth * num / den                  // 960
    static let height = baseHeight * num / den                // 600
    static let statusBarHeight = baseStatusBar * num / den    // 120
    static var viewHeight: Int { height - statusBarHeight }   // 480 — the 3-D viewport
    static var horizon: Int { viewHeight / 2 }                // 240
    /// Camera-plane half-width. 0.66 ≈ a 66° horizontal FOV at the 2:1 viewport.
    static let cameraPlane: Float = 0.66
}

/// Scale a logical-640×400 coordinate or size to the framebuffer (the UI layout
/// is written at 1× and scaled through these, so the resolution stays one knob).
@inline(__always) func uiS(_ v: Int) -> Int { v * RenderConfig.num / RenderConfig.den }
@inline(__always) func uiSf(_ v: CGFloat) -> CGFloat { v * CGFloat(RenderConfig.num) / CGFloat(RenderConfig.den) }

final class Canvas2D {
    let width: Int
    let height: Int
    let framebuffer: UnsafeMutablePointer<UInt32>
    /// Per-column perpendicular wall distance, written by the raycaster, read
    /// by sprite drawing for occlusion. `width` entries.
    let zbuffer: UnsafeMutablePointer<Float>
    private let count: Int

    init(width: Int = RenderConfig.width, height: Int = RenderConfig.height) {
        self.width = width
        self.height = height
        self.count = width * height
        framebuffer = .allocate(capacity: count)
        framebuffer.initialize(repeating: 0xFF00_0000, count: count)
        zbuffer = .allocate(capacity: width)
        zbuffer.initialize(repeating: .greatestFiniteMagnitude, count: width)
    }

    deinit {
        framebuffer.deallocate()
        zbuffer.deallocate()
    }

    // ── Core pixel ops ────────────────────────────────────────────────────

    @inline(__always) func plot(_ x: Int, _ y: Int, _ color: UInt32) {
        if x >= 0 && x < width && y >= 0 && y < height {
            framebuffer[y * width + x] = color
        }
    }

    /// Direct index write — caller guarantees bounds (hot raycaster paths).
    @inline(__always) func raw(_ index: Int, _ color: UInt32) {
        framebuffer[index] = color
    }

    @inline(__always) func blend(_ x: Int, _ y: Int, _ color: UInt32, _ a: Float) {
        if x < 0 || x >= width || y < 0 || y >= height || a <= 0 { return }
        let i = y * width + x
        if a >= 1 { framebuffer[i] = color; return }
        let d = framebuffer[i]
        let ia = 1 - a
        let rr = Float(color & 0xFF) * a + Float(d & 0xFF) * ia
        let gg = Float((color >> 8) & 0xFF) * a + Float((d >> 8) & 0xFF) * ia
        let bb = Float((color >> 16) & 0xFF) * a + Float((d >> 16) & 0xFF) * ia
        framebuffer[i] = packRGBA(UInt8(rr), UInt8(gg), UInt8(bb))
    }

    /// Additive blend — adds `color * a` to the destination (clamped). For fire
    /// and other glows that should brighten where they overlap.
    @inline(__always) func blendAdd(_ x: Int, _ y: Int, _ color: UInt32, _ a: Float) {
        if x < 0 || x >= width || y < 0 || y >= height || a <= 0 { return }
        let i = y * width + x
        let d = framebuffer[i]
        let rr = min(255, Int(d & 0xFF) + Int(Float(color & 0xFF) * a))
        let gg = min(255, Int((d >> 8) & 0xFF) + Int(Float((color >> 8) & 0xFF) * a))
        let bb = min(255, Int((d >> 16) & 0xFF) + Int(Float((color >> 16) & 0xFF) * a))
        framebuffer[i] = packRGBA(UInt8(rr), UInt8(gg), UInt8(bb))
    }

    // ── Fills & lines ─────────────────────────────────────────────────────

    func clear(_ color: UInt32 = 0xFF00_0000) {
        framebuffer.update(repeating: color, count: count)
    }

    func resetZ() {
        zbuffer.update(repeating: .greatestFiniteMagnitude, count: width)
    }

    func fillRect(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        let xa = max(0, x0), xb = min(width, x0 + w)
        let ya = max(0, y0), yb = min(height, y0 + h)
        if xa >= xb || ya >= yb { return }
        for y in ya..<yb {
            let base = y * width
            for x in xa..<xb { framebuffer[base + x] = color }
        }
    }

    func fillRectBlend(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ color: UInt32, _ a: Float) {
        let xa = max(0, x0), xb = min(width, x0 + w)
        let ya = max(0, y0), yb = min(height, y0 + h)
        if xa >= xb || ya >= yb { return }
        for y in ya..<yb { for x in xa..<xb { blend(x, y, color, a) } }
    }

    func hLine(_ x0: Int, _ x1: Int, _ y: Int, _ color: UInt32) {
        if y < 0 || y >= height { return }
        let a = max(0, min(x0, x1)), b = min(width - 1, max(x0, x1))
        if a > b { return }
        let base = y * width
        for x in a...b { framebuffer[base + x] = color }
    }

    func vLine(_ x: Int, _ y0: Int, _ y1: Int, _ color: UInt32) {
        if x < 0 || x >= width { return }
        let a = max(0, min(y0, y1)), b = min(height - 1, max(y0, y1))
        if a > b { return }
        for y in a...b { framebuffer[y * width + x] = color }
    }

    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: UInt32) {
        var x0 = x0, y0 = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            plot(x0, y0, color)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    /// Outline rectangle.
    func strokeRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        hLine(x, x + w - 1, y, color)
        hLine(x, x + w - 1, y + h - 1, color)
        vLine(x, y, y + h - 1, color)
        vLine(x + w - 1, y, y + h - 1, color)
    }

    // ── Sprites / bitmaps ─────────────────────────────────────────────────

    /// Blit an RGBA bitmap with integer scaling; fully transparent pixels
    /// (alpha 0) are skipped, partial alpha is blended. No z-test (HUD / menus
    /// / weapon viewmodel). `tint` multiplies RGB if given (pain flash, etc.).
    func blitBitmap(_ pixels: [UInt32], _ pw: Int, _ ph: Int, _ dx: Int, _ dy: Int,
                    scale: Int = 1, tint: Float = 1) {
        if pw <= 0 || ph <= 0 { return }
        pixels.withUnsafeBufferPointer { src in
            for sy in 0..<ph {
                let row = sy * pw
                for py in 0..<scale {
                    let oy = dy + sy * scale + py
                    if oy < 0 || oy >= height { continue }
                    let obase = oy * width
                    for sx in 0..<pw {
                        let c = src[row + sx]
                        let a = c >> 24
                        if a == 0 { continue }
                        let col = tint < 0.999 ? shade(c, tint) : c
                        let af = Float(a) / 255
                        for px in 0..<scale {
                            let ox = dx + sx * scale + px
                            if ox < 0 || ox >= width { continue }
                            if a == 255 { framebuffer[obase + ox] = col }
                            else { blend(ox, oy, col, af) }
                        }
                    }
                }
            }
        }
    }

    /// Blit an RGBA bitmap at a fractional scale (nearest), for the weapon
    /// viewmodel and other fixed sprites that must track the framebuffer scale.
    func blitBitmapF(_ pixels: [UInt32], _ pw: Int, _ ph: Int, _ dx: Int, _ dy: Int, scale: Float) {
        let dw = Int(Float(pw) * scale), dh = Int(Float(ph) * scale)
        if dw <= 0 || dh <= 0 { return }
        pixels.withUnsafeBufferPointer { src in
            for oy in 0..<dh {
                let yy = dy + oy
                if yy < 0 || yy >= height { continue }
                let srow = min(ph - 1, Int(Float(oy) / scale)) * pw, drow = yy * width
                for ox in 0..<dw {
                    let c = src[srow + min(pw - 1, Int(Float(ox) / scale))]
                    let a = c >> 24
                    if a == 0 { continue }
                    let xx = dx + ox
                    if xx < 0 || xx >= width { continue }
                    if a == 255 { framebuffer[drow + xx] = c } else { blend(xx, yy, c, Float(a) / 255) }
                }
            }
        }
    }

    // ── Text ──────────────────────────────────────────────────────────────

    func text(_ s: String, _ x: Int, _ y: Int, scale: Int = 1, color: UInt32 = 0xFFFF_FFFF,
              shadow: UInt32? = packRGBA(0, 0, 0), alpha: Float = 1) {
        Font.draw(s, into: framebuffer, w: width, h: height, x: x, y: y, scale: scale,
                  color: color, shadow: shadow, alpha: alpha)
    }

    func textCentered(_ s: String, _ y: Int, scale: Int = 1, color: UInt32 = 0xFFFF_FFFF,
                       shadow: UInt32? = packRGBA(0, 0, 0), alpha: Float = 1) {
        let x = (width - Font.width(s, scale: scale)) / 2
        text(s, x, y, scale: scale, color: color, shadow: shadow, alpha: alpha)
    }

    /// Composite a Core Text bitmap (premultiplied RGBA) — used for unicode
    /// high-score names. `out = src + dst*(1-a)`.
    func drawTextImage(_ bmp: TextImage.Bitmap, _ dx: Int, _ dy: Int) {
        bmp.pixels.withUnsafeBufferPointer { src in
            for sy in 0..<bmp.h {
                let oy = dy + sy
                if oy < 0 || oy >= height { continue }
                let row = sy * bmp.w
                let obase = oy * width
                for sx in 0..<bmp.w {
                    let c = src[row + sx]
                    let a = (c >> 24) & 0xFF
                    if a == 0 { continue }
                    let ox = dx + sx
                    if ox < 0 || ox >= width { continue }
                    if a == 255 { framebuffer[obase + ox] = c | 0xFF00_0000; continue }
                    let ia = 1 - Float(a) / 255
                    let d = framebuffer[obase + ox]
                    // src is premultiplied: out = src + dst*(1-a)
                    let rr = Float(c & 0xFF) + Float(d & 0xFF) * ia
                    let gg = Float((c >> 8) & 0xFF) + Float((d >> 8) & 0xFF) * ia
                    let bb = Float((c >> 16) & 0xFF) + Float((d >> 16) & 0xFF) * ia
                    framebuffer[obase + ox] = packRGBA(UInt8(clamping: Int(rr)),
                                                       UInt8(clamping: Int(gg)),
                                                       UInt8(clamping: Int(bb)))
                }
            }
        }
    }

    func drawUnicodeCentered(_ s: String, _ y: Int, fontSize: CGFloat,
                             _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        guard let bmp = TextImage.rasterize(s, fontSize: fontSize, r: r, g: g, b: b) else { return }
        drawTextImage(bmp, (width - bmp.w) / 2, y)
    }

    // ── Core Text labels (crisp, cached) ───────────────────────────────────

    func labelWidth(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> Int {
        TextImage.cached(s, size: size, weight: weight, color: 0xFFFF_FFFF, mono: mono)?.w ?? 0
    }

    func labelHeight(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> Int {
        TextImage.cached(s, size: size, weight: weight, color: 0xFFFF_FFFF, mono: mono)?.h ?? 0
    }

    func label(_ s: String, _ x: Int, _ y: Int, size: CGFloat, color: UInt32 = 0xFFFF_FFFF,
               weight: NSFont.Weight = .regular, shadow: Bool = true, glow: UInt32? = nil, mono: Bool = false) {
        if let glowColor = glow, let g = TextImage.cached(s, size: size, weight: weight, color: glowColor, mono: mono) {
            for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { drawTextImage(g, x + ox, y + oy) }
        }
        if shadow, let sh = TextImage.cached(s, size: size, weight: weight, color: 0xFF00_0000, mono: mono) {
            drawTextImage(sh, x + 1, y + 1)
        }
        if let b = TextImage.cached(s, size: size, weight: weight, color: color, mono: mono) { drawTextImage(b, x, y) }
    }

    func labelCentered(_ s: String, _ y: Int, size: CGFloat, color: UInt32 = 0xFFFF_FFFF,
                       weight: NSFont.Weight = .regular, shadow: Bool = true, glow: UInt32? = nil, mono: Bool = false) {
        let w = labelWidth(s, size: size, weight: weight, mono: mono)
        label(s, (width - w) / 2, y, size: size, color: color, weight: weight, shadow: shadow, glow: glow, mono: mono)
    }

    /// Right edge of the text sits at `rightX`.
    func labelRight(_ s: String, _ rightX: Int, _ y: Int, size: CGFloat, color: UInt32 = 0xFFFF_FFFF,
                    weight: NSFont.Weight = .regular, shadow: Bool = true, mono: Bool = false) {
        let w = labelWidth(s, size: size, weight: weight, mono: mono)
        label(s, rightX - w, y, size: size, color: color, weight: weight, shadow: shadow, mono: mono)
    }

    /// Centre text within the column [x0, x0+w).
    func labelCentered2(_ s: String, _ x0: Int, _ w: Int, _ y: Int, size: CGFloat, color: UInt32 = 0xFFFF_FFFF,
                        weight: NSFont.Weight = .regular, shadow: Bool = true, glow: UInt32? = nil, mono: Bool = false) {
        let tw = labelWidth(s, size: size, weight: weight, mono: mono)
        label(s, x0 + (w - tw) / 2, y, size: size, color: color, weight: weight, shadow: shadow, glow: glow, mono: mono)
    }
}
