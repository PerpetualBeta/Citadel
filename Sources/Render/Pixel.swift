// Citadel — packed-RGBA pixel helpers.
//
// The whole game draws into a flat UInt32 framebuffer (Canvas2D). Pixels are
// packed RGBA, little-endian: R in the low byte, A in the high byte — the
// layout Metal's .rgba8Unorm texture expects, so the framebuffer uploads with
// no swizzle. Everything that touches colour goes through here.

import Foundation

@inline(__always) func packRGBA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
}

@inline(__always) func packRGBA(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> UInt32 {
    return packRGBA(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b), UInt8(clamping: a))
}

@inline(__always) func redOf(_ c: UInt32) -> Int   { Int(c & 0xFF) }
@inline(__always) func greenOf(_ c: UInt32) -> Int { Int((c >> 8) & 0xFF) }
@inline(__always) func blueOf(_ c: UInt32) -> Int  { Int((c >> 16) & 0xFF) }
@inline(__always) func alphaOf(_ c: UInt32) -> Int { Int((c >> 24) & 0xFF) }

/// Multiply a colour's RGB by brightness `k` (0…1+), preserving alpha. The
/// raycaster uses this for distance/sector light diminishing.
@inline(__always) func shade(_ c: UInt32, _ k: Float) -> UInt32 {
    let r = Float(c & 0xFF) * k
    let g = Float((c >> 8) & 0xFF) * k
    let b = Float((c >> 16) & 0xFF) * k
    return packRGBA(UInt8(clamping: Int(r)), UInt8(clamping: Int(g)),
                    UInt8(clamping: Int(b)), UInt8((c >> 24) & 0xFF))
}

/// Multiply a colour's RGB by a *per-channel* light colour, preserving alpha.
/// Colored sector lighting uses this: each channel gets its own gain, so a
/// surface in green light goes green, in red light goes red. `shade` is the
/// monochrome special case (kr == kg == kb).
@inline(__always) func shadeRGB(_ c: UInt32, _ kr: Float, _ kg: Float, _ kb: Float) -> UInt32 {
    let r = Float(c & 0xFF) * kr
    let g = Float((c >> 8) & 0xFF) * kg
    let b = Float((c >> 16) & 0xFF) * kb
    return packRGBA(UInt8(clamping: Int(r)), UInt8(clamping: Int(g)),
                    UInt8(clamping: Int(b)), UInt8((c >> 24) & 0xFF))
}

/// Linear blend from `a` to `b` by `t` (0…1) in packed RGBA (RGB only).
@inline(__always) func mixRGBA(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
    let it = 1 - t
    let r = Float(a & 0xFF) * it + Float(b & 0xFF) * t
    let g = Float((a >> 8) & 0xFF) * it + Float((b >> 8) & 0xFF) * t
    let bb = Float((a >> 16) & 0xFF) * it + Float((b >> 16) & 0xFF) * t
    return packRGBA(UInt8(clamping: Int(r)), UInt8(clamping: Int(g)), UInt8(clamping: Int(bb)))
}
