// Citadel — billboard sprite & particle compositor.
//
// The depth-sorted billboards (monsters/items/projectiles/props) and particles,
// drawn against the framebuffer's z-buffer. Used two ways:
//   • the GPU renderer calls overlayThings(): the SDF kernel draws the world +
//     creatures, then this composites the things the kernel doesn't raymarch
//     (props + particles) with per-pixel depth occlusion from the read-back depth;
//   • the CPU raycaster calls drawThings() after casting its walls/floor.
// Shading reuses the shared CPU light model in WorldLight.

import Foundation
import simd

struct SpriteCompositor {
    let viewW = RenderConfig.width
    let viewH = RenderConfig.viewHeight
    let horizon = RenderConfig.horizon

    private struct Renderable { let dist: Float; let kind: Int; let index: Int }

    /// GPU-renderer overlay: the SDF kernel draws the world + creatures, but
    /// items / projectiles / particles are still sprites. Fill the z-buffer from
    /// the walls (depth-only DDA) so they occlude correctly, then draw them.
    func overlayThings(_ world: World, into c: Canvas2D, depth: UnsafePointer<Float>? = nil, includeProjectiles: Bool = true,
                       includeDrums: Bool = true, includeSockets: Bool = true, includeMines: Bool = true) {
        let p = world.player
        let dirX = cos(p.dir), dirY = sin(p.dir)
        let planeX = -sin(p.dir) * RenderConfig.cameraPlane
        let planeY = cos(p.dir) * RenderConfig.cameraPlane
        let map = world.map
        let W = viewW
        // The z-buffer fill below is only consumed on the CPU-fallback path
        // (depth == nil, i.e. the headless SmokeTest). On the shipping GPU path the
        // caller passes the read-back GPU depth, which drawThings reads instead — so
        // skip this whole per-column wall-DDA, which otherwise runs W times a frame
        // purely to fill a buffer nobody reads.
        if depth == nil {
            c.resetZ()
            for x in 0..<W {
                let cameraX = 2 * Float(x) / Float(W) - 1
                let rayX = dirX + planeX * cameraX, rayY = dirY + planeY * cameraX
                var mapX = Int(p.pos.x), mapY = Int(p.pos.y)
                let deltaX = rayX == 0 ? 1e30 : abs(1 / rayX), deltaY = rayY == 0 ? 1e30 : abs(1 / rayY)
                var stepX = 0, stepY = 0, sideX: Float = 0, sideY: Float = 0
                if rayX < 0 { stepX = -1; sideX = (p.pos.x - Float(mapX)) * deltaX } else { stepX = 1; sideX = (Float(mapX) + 1 - p.pos.x) * deltaX }
                if rayY < 0 { stepY = -1; sideY = (p.pos.y - Float(mapY)) * deltaY } else { stepY = 1; sideY = (Float(mapY) + 1 - p.pos.y) * deltaY }
                var side = 0, iter = 0, dist: Float = 0.0001
                while iter < 256 {
                    iter += 1
                    if sideX < sideY { sideX += deltaX; mapX += stepX; side = 0 } else { sideY += deltaY; mapY += stepY; side = 1 }
                    let id = map.wallAt(mapX, mapY)
                    if id == 0 { continue }
                    if map.inBounds(mapX, mapY), let d = map.doors[map.idx(mapX, mapY)], d.open > 0 {
                        if d.open >= GameMap.passThreshold { continue }   // fully retracted
                        // centre-split: sprites show through the widening slit, are occluded by the panels
                        let dd = max(0.0001, side == 0 ? (sideX - deltaX) : (sideY - deltaY))
                        let hu = side == 0 ? (p.pos.y + dd * rayY) : (p.pos.x + dd * rayX)
                        let s = 0.5 * min(1, d.open / GameMap.passThreshold)
                        if abs((hu - floor(hu)) - 0.5) < s { continue }
                    }
                    dist = max(0.0001, side == 0 ? (sideX - deltaX) : (sideY - deltaY)); break
                }
                c.zbuffer[x] = dist
            }
        }
        let t = world.elapsed
        let flick: Float = 1 + 0.035 * sinf(t * 8.7) + 0.025 * sinf(t * 21.3 + 1.7)
        let lights = WorldLight.colored ? WorldLight.gatherLights(world) : []
        let hl = WorldLight.colored ? WorldLight.makeHeadlamp(world, dirX, dirY) : nil
        drawThings(world, into: c, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY,
                   flick: flick, lights: lights, hasDyn: !lights.isEmpty, headlamp: hl,
                   includeItems: false,
                   includeProjectiles: includeProjectiles,
                   includeDrums: includeDrums, includeSockets: includeSockets, includeMines: includeMines,
                   depthBuf: depth)   // monsters/items/projectiles/drums/sockets are SDF on the GPU path
    }

    func drawThings(_ world: World, into c: Canvas2D, dirX: Float, dirY: Float,
                    planeX: Float, planeY: Float, flick: Float, lights: [WorldLight.DynLight], hasDyn: Bool,
                    headlamp: WorldLight.Headlamp? = nil,
                    includeItems: Bool = true,
                    includeProjectiles: Bool = true,
                    includeDrums: Bool = true, includeSockets: Bool = true, includeMines: Bool = true,
                    depthBuf: UnsafePointer<Float>? = nil) {
        let p = world.player
        let sprites = Sprites.shared
        var things: [Renderable] = []
        if includeItems { for (i, it) in world.items.enumerated() where !it.taken { things.append(Renderable(dist: vlen(it.pos - p.pos), kind: 1, index: i)) } }
        if includeProjectiles { for (i, pr) in world.projectiles.enumerated() { things.append(Renderable(dist: vlen(pr.pos - p.pos), kind: 2, index: i)) } }
        // world props — drums + sockets are SDF on the GPU path (gated off there);
        // deployed mines are still billboards on both paths. The CPU raycaster draws
        // all three as sprites (its fallback path has no kernel).
        if includeDrums { for (i, d) in world.drums.enumerated() { things.append(Renderable(dist: vlen(d.pos - p.pos), kind: 4, index: i)) } }
        if includeMines { for (i, mn) in world.deployedMines.enumerated() { things.append(Renderable(dist: vlen(mn.pos - p.pos), kind: 5, index: i)) } }
        if includeSockets { for (i, sk) in world.sockets.enumerated() { things.append(Renderable(dist: vlen(sk.pos - p.pos), kind: 6, index: i)) } }
        for i in world.particles.indices { things.append(Renderable(dist: vlen(world.particles[i].pos - p.pos), kind: 3, index: i)) }
        things.sort { $0.dist > $1.dist }

        // Under heavy combat the additive fire stack saturates long before every
        // orb has drawn its full O(r²) footprint — the frame pays for pixels the
        // eye can't see. Estimate the frame's total particle blend load and, when
        // over budget, shrink every radius by ONE uniform factor (ops fall with
        // its square). Normal scenes are untouched; a mine-into-drum-chain frame
        // degrades gracefully instead of collapsing.
        var estOps = 0.0
        for t in things where t.kind == 3 {
            let pa = world.particles[t.index]
            if pa.fire && pa.color != 0 { continue }         // sparks are 2 px — don't let them shrink the fire
            let re = Double(min(Float(RenderConfig.projHeight) / max(0.15, t.dist) * 0.05 * pa.size, Float(viewH) / 4))
            estOps += 3.14159 * re * re / (re > 56 ? 2 : 1) / (re > 120 ? 2 : 1)
        }
        let opsBudget = 0.55 * Double(viewW * viewH)         // measured ~20 ns per scattered blend: this holds the composite near ~10 ms
        let particleScale = estOps > opsBudget ? Float((opsBudget / estOps).squareRoot()) : 1

        let invDet = 1 / (planeX * dirY - dirX * planeY)
        for thing in things {
            let pos: SIMD2<Float>
            let spr: Sprite
            var billboardH: Float = 0.9
            var tint: UInt32 = 0, tintAmt: Float = 0
            var vBias: Float = 0
            var emissive = false   // projectiles/cores ignore darkness
            var dissolve: Float = 0  // a corpse melting into a toxic pool
            var groundFade = false   // a corpse's soft floor contact
            var extraGlow = SIMD3<Float>(0, 0, 0)  // a prop's own light (e.g. a mine's LED)

            switch thing.kind {
            case 1:
                let it = world.items[thing.index]
                spr = sprites.item(it.kind); pos = it.pos; billboardH = 0.42
                vBias = 0.05 + 0.03 * sin(it.bob + world.elapsed * 3)
            case 2:
                let pr = world.projectiles[thing.index]
                spr = sprites.projectile(pr.kind); pos = pr.pos; billboardH = 0.34; vBias = 0.4; emissive = true
            case 4:
                let d = world.drums[thing.index]
                spr = sprites.prop(.fuelDrum); pos = d.pos; billboardH = 0.55
                if d.hitFlash > 0 { tint = packRGBA(255, 220, 180); tintAmt = 0.55 * d.hitFlash }
            case 5:
                let mn = world.deployedMines[thing.index]
                spr = sprites.prop(.proxMine); pos = mn.pos; billboardH = 0.16; vBias = 0.02
                // the trigger lamp pulses (fast once armed) so you can spot a mine
                // in the dark and not walk a drone over your own
                let pulse = mn.arm <= 0 ? (0.45 + 0.55 * sin(mn.blink * 7)) : 0.3
                extraGlow = SIMD3(0.42, 0.05, 0.03) * max(0, pulse)
            case 6:
                let sk = world.sockets[thing.index]
                spr = sprites.prop(.socket); pos = sk.pos; billboardH = 0.5
                // the energy cell glows cyan while charged — pulsing so you can spot
                // it in the dark — and goes dark once drained
                let lit: Float = sk.charge > 0 ? (0.45 + 0.4 * sin(sk.pulse * 4)) : 0.05
                extraGlow = SIMD3(0.10, 0.40, 0.55) * lit
            default:
                drawParticle(world.particles[thing.index], into: c, p: p, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY, invDet: invDet, scale: particleScale, depthBuf: depthBuf)
                continue
            }

            let rel = pos - p.pos
            let tX = invDet * (dirY * rel.x - dirX * rel.y)
            let tY = invDet * (-planeY * rel.x + planeX * rel.y)
            if tY <= 0.12 { continue }
            let lightB = emissive ? 1.0 : WorldLight.brightness(tY, flick)
            // a thing sits IN the local light colour — a creature in green nukage
            // glow reads green, like the walls around it. Emissive things ignore it.
            var lightCol = SIMD3<Float>(1, 1, 1)
            var dyn = (Float(0), Float(0), Float(0))
            if WorldLight.colored && !emissive {
                if WorldLight.smoothLight {
                    lightCol = WorldLight.lightAt(world.map, pos.x, pos.y)
                } else {
                    let mcx = Int(pos.x), mcy = Int(pos.y)
                    if world.map.inBounds(mcx, mcy) { lightCol = world.map.lightColor[world.map.idx(mcx, mcy)] }
                }
                if hasDyn { dyn = WorldLight.dynAt(lights, pos.x, pos.y) }   // muzzle flash / fireball lights the creature
                // the headlamp picks the thing out of the dark — you see the alien
                // when your beam falls on it (and not a moment before)
                if let hl = headlamp { let h = WorldLight.hlAt(hl, pos.x, pos.y); dyn.0 += h.0; dyn.1 += h.1; dyn.2 += h.2 }
                dyn.0 += extraGlow.x; dyn.1 += extraGlow.y; dyn.2 += extraGlow.z   // the prop's own lamp
            }
            drawSprite(spr, c: c, transformX: tX, transformY: tY, billboardH: billboardH,
                       vBias: vBias, tint: tint, tintAmt: tintAmt, lightB: lightB, lightCol: lightCol,
                       dissolve: dissolve, dynLight: dyn, groundFade: groundFade, depthBuf: depthBuf)
        }
    }

    private func drawSprite(_ spr: Sprite, c: Canvas2D, transformX: Float, transformY: Float,
                            billboardH: Float, vBias: Float, tint: UInt32, tintAmt: Float,
                            lightB: Float, lightCol: SIMD3<Float>, dissolve: Float = 0,
                            dynLight: (Float, Float, Float) = (0, 0, 0), groundFade: Bool = false,
                            depthBuf: UnsafePointer<Float>? = nil) {
        let W = viewW
        // vertical scale pinned to the 2:1-calibrated projection (matches the kernel)
        let lineFull = Float(RenderConfig.projHeight) / transformY
        let screenX = Int(Float(W) / 2 * (1 + transformX / transformY))
        let spriteH = Int(lineFull * billboardH)
        if spriteH < 1 { return }
        let spriteW = max(1, Int(Float(spriteH) * Float(spr.w) / Float(spr.h)))
        let bottom = horizon + Int(lineFull * 0.5) - Int(lineFull * vBias)
        let top = bottom - spriteH
        let fb = c.framebuffer
        let x0 = screenX - spriteW / 2
        let acid = packRGBA(120, 210, 70)
        // a corpse in nukage SINKS and melts: below a ragged per-column waterline
        // it tints toxic-green, darkens and fades to nothing — no holes/hatching.
        let eat = dissolve * 0.22
        spr.pixels.withUnsafeBufferPointer { src in
            for sx in 0..<spriteW {
                let col = x0 + sx
                if col < 0 || col >= W { continue }
                if depthBuf == nil && transformY >= c.zbuffer[col] { continue }   // per-column (CPU path)
                let texX = sx * spr.w / spriteW
                // per-column ragged waterline (well-distributed hash; no diagonal banding)
                var waterline: Float = 0
                if dissolve > 0 {
                    var h = UInt32(truncatingIfNeeded: col &* 374_761_393)
                    h = (h ^ (h >> 13)) &* 1_274_126_177; h ^= (h >> 16)
                    waterline = eat + (Float(h & 0xFF) / 255 - 0.5) * 0.05
                }
                for sy in 0..<spriteH {
                    let row = top + sy
                    if row < 0 || row >= viewH { continue }
                    if let db = depthBuf, transformY >= db[row * W + col] { continue }   // per-pixel (GPU path)
                    let texY = sy * spr.h / spriteH
                    let raw = src[texY * spr.w + texX]
                    let a = raw >> 24
                    if a == 0 { continue }
                    var col32 = shadeRGB(raw, lightB * lightCol.x + dynLight.0,
                                         lightB * lightCol.y + dynLight.1, lightB * lightCol.z + dynLight.2)
                    var aMul: Float = 1
                    let up = Float(spriteH - sy) / Float(spriteH)       // 0 at base … 1 at top
                    if dissolve > 0 {
                        if up < waterline {                             // submerged — melting into the pool
                            let bf = min(1, (waterline - up) / max(0.03, waterline))
                            col32 = shade(mixRGBA(col32, acid, 0.45 + 0.4 * bf), 0.8 - 0.45 * bf)
                            aMul = max(0, 1 - bf * 1.25)
                        } else if up < waterline + 0.07 {               // bright acid-bitten surface line
                            col32 = mixRGBA(col32, packRGBA(170, 255, 140), 0.5)
                        }
                    }
                    // soft floor contact for corpses: fade the bottom edge so the
                    // blood pool melts into the floor instead of a hard straight line
                    if groundFade && up < 0.11 { aMul *= max(0, up / 0.11) }
                    if tintAmt > 0 { col32 = mixRGBA(col32, tint, tintAmt) }
                    let fa = Float(a) / 255 * aMul
                    if fa <= 0.004 { continue }
                    if fa >= 0.999 { fb[row * W + col] = col32 } else { c.blend(col, row, col32, fa) }
                }
            }
        }
    }

    /// (1 − √(d²/r²))² falloff by normalised squared distance. The per-pixel
    /// sqrt inside the O(r²) particle loops was the compositor's hottest single
    /// instruction under combat load — this table replaces it with one multiply.
    private static let fallLUT: [Float] = (0...256).map { let f = 1 - (Float($0) / 256).squareRoot(); return f * f }

    private func drawParticle(_ pa: Particle, into c: Canvas2D, p: Player,
                              dirX: Float, dirY: Float, planeX: Float, planeY: Float, invDet: Float, scale: Float = 1,
                              depthBuf: UnsafePointer<Float>? = nil) {
        let rel = pa.pos - p.pos
        let tX = invDet * (dirY * rel.x - dirX * rel.y)
        let tY = invDet * (-planeY * rel.x + planeX * rel.y)
        if tY <= 0.15 { return }
        let W = viewW
        let lineFull = Float(RenderConfig.projHeight) / tY
        let screenX = Int(Float(W) / 2 * (1 + tX / tY))
        let screenY = horizon + Int(lineFull * 0.5) - Int(lineFull * pa.height)
        if screenX < 0 || screenX >= W { return }
        // Occlude against the GPU per-pixel depth (which includes dynamic doors) so a
        // spark behind the sealed elevator door — or any wall — is culled. Fall back
        // to the CPU per-column z-buffer (which is wall-only, so it misses doors).
        let occ = depthBuf.map { $0[min(max(screenY, 0), viewH - 1) * W + screenX] } ?? c.zbuffer[screenX]
        if tY >= occ { return }
        // CAP + STRIDE: a soft particle right at the camera used to project to a
        // radius of THOUSANDS of pixels, and this loop is O(r²) CPU pixel blends —
        // one close flame could demand tens of millions of read-modify-writes and
        // the frame rate collapsed near any pyre. The radius caps at a QUARTER of
        // the view (a flame can still fill the screen when tongues overlap), and
        // big glows draw alternate ROWS at doubled weight — exact integrated
        // energy, and the scanline dither vanishes inside the additive stack.
        // (The first cut capped at viewH/8 with under-weighted dither and the
        // fire looked pathetic — this keeps the drama at ~1/6 the worst cost.)
        let r = max(1, min(Int(lineFull * 0.05 * pa.size * scale), viewH / 4))
        let stride = r > 56 ? 2 : 1
        let colStride = r > 120 ? 2 : 1        // the biggest orbs also skip columns (quincunx — invisible in the additive stack)
        let weight = Float(stride * colStride)
        let rr = r * r
        let invRR = 256.0 / Float(rr)
        let lifeF = max(0, min(1, pa.life / pa.maxLife))
        // One row-clamp + one sqrt per ROW (the circle's half-width) replaces the
        // per-pixel radius test + bounds check; blendAddU/blendU skip re-checking.
        if pa.fire {
            if pa.color == 0 {
                // flame: soft additive glow, age-ramped white-hot → orange → deep
                // red → smoke (overlapping tongues build a body of flame)
                let age = 1 - lifeF
                let col: UInt32
                if age < 0.25 { col = mixRGBA(packRGBA(255, 250, 210), packRGBA(255, 196, 70), age / 0.25) }
                else if age < 0.6 { col = mixRGBA(packRGBA(255, 196, 70), packRGBA(232, 96, 26), (age - 0.25) / 0.35) }
                else { col = mixRGBA(packRGBA(232, 96, 26), packRGBA(60, 46, 44), (age - 0.6) / 0.4) }
                let glow = (1 - age) * pa.maxAlpha * weight
                var oy = -r
                while oy <= r {
                    let py = screenY + oy
                    if py < 0 || py >= c.height { oy += stride; continue }
                    let hw = Int(Double(rr - oy * oy).squareRoot())
                    var ox = max(-hw, -screenX)
                    let oxEnd = min(hw, c.width - 1 - screenX)
                    if colStride == 2 { ox += (ox + oy) & 1 }
                    while ox <= oxEnd {
                        let d2 = ox * ox + oy * oy
                        c.blendAdd(screenX + ox, py, col, glow * Self.fallLUT[min(256, Int(Float(d2) * invRR))])
                        ox += colStride
                    }
                    oy += stride
                }
            } else {
                // spark: a sharp, tiny, bright glint (1–2px, flat additive — NOT a
                // soft orb) with a short streak trailing its arc through the air
                let sa = lifeF * pa.maxAlpha
                let sr = min(1, r)              // tight, sharp core — not a soft orb
                for oy in -sr...sr { for ox in -sr...sr {
                    if ox * ox + oy * oy > sr * sr + 1 { continue }
                    c.blendAdd(screenX + ox, screenY + oy, pa.color, sa)
                }}
                // a longer comet streak trailing up behind the falling glint, so a
                // burst reads clearly as a shower of flying sparks (was a faint dot)
                for t in 1...6 {
                    c.blendAdd(screenX, screenY - sr - t, pa.color, sa * (1 - Float(t) / 7))
                }
            }
            return
        }
        let a = lifeF * pa.maxAlpha * weight
        var oy2 = -r
        while oy2 <= r {
            let py = screenY + oy2
            if py < 0 || py >= c.height { oy2 += stride; continue }
            let hw = Int(Double(rr - oy2 * oy2).squareRoot())
            var ox2 = max(-hw, -screenX)
            let oxEnd = min(hw, c.width - 1 - screenX)
            if colStride == 2 { ox2 += (ox2 + oy2) & 1 }
            while ox2 <= oxEnd {
                let d2 = ox2 * ox2 + oy2 * oy2
                c.blend(screenX + ox2, py, pa.color, a * Self.fallLUT[min(256, Int(Float(d2) * invRR))])
                ox2 += colStride
            }
            oy2 += stride
        }
        return
    }
}
