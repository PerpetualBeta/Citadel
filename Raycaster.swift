// Citadel — the raycaster.
//
// A textured DDA raycaster in the Doom idiom, drawing into the top `viewHeight`
// rows of the Canvas2D framebuffer. The lighting is built for DREAD: surfaces
// near the marine are lit, everything beyond falls off exponentially into
// near-black, so you can never see far and the citadel feels like it's closing
// in. An ordered (Bayer) dither smooths the dark gradients so they read as
// atmosphere rather than banding, and a subtle power-flicker keeps it uneasy.
//   1. per-row floor & ceiling texture casting,
//   2. per-column DDA walls with centre-split sliding doors,
//   3. depth-sorted billboarded sprites + particles against the z-buffer.

import Foundation
import simd

struct Raycaster {
    let viewW = RenderConfig.width
    let viewH = RenderConfig.viewHeight
    let horizon = RenderConfig.horizon

    // Bayer 4×4, centred to roughly [-0.5, 0.5] for ordered dithering.
    private static let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { Float($0) / 16 - 0.469 }
    @inline(__always) private func dither(_ x: Int, _ y: Int) -> Float { Raycaster.bayer[(y & 3) * 4 + (x & 3)] }

    // light model — the distance term (the "dread" falloff). Surfaces near the
    // marine are lit; everything beyond falls off into near-black. In colored
    // mode this scalar is multiplied per-channel by the cell's baked light
    // COLOUR (Lighting.bake); in legacy mode it multiplies the old scalar light.
    private let ambient: Float = 0.05
    private let glow: Float = 1.28
    private let falloff: Float = 0.16

    // ── auto-headlamp ───────────────────────────────────────────────────────────
    // The marine's helmet lamp. A soft forward cone (plus a small spill pool at
    // the feet) whose intensity AUTO-RAMPS with the baked light the marine is
    // standing in — near-full in unlit pockets, eased down in lit rooms so the
    // designed sector lighting still reads. A cool LED white against the cold iron.
    private static let lampColor = SIMD3<Float>(0.78, 0.85, 1.00)
    private let lampReach: Float = 8.5     // cells the beam carries before it dies
    private let lampNear: Float = 1.8      // radius of the omnidirectional feet-spill
    private let lampPeak: Float = 0.95     // contribution at the bright core (× gain)
    private let lampGainFloor: Float = 0.16   // the lamp never goes fully dark
    private let lampCosInner: Float = 0.88    // full brightness within ~28°
    private let lampCosOuter: Float = 0.40    // faded to nothing by ~66°
    private let lampLitRef: Float = 0.62      // baked luma at/above which the lamp idles
    private let lampDarkRef: Float = 0.12     // baked luma at/below which the lamp is full

    /// Colored sector lighting on (the game) vs the old monochrome path (the
    /// before/after preview flips this).
    static var colored = true

    /// Bilinearly interpolate the per-cell light field so pools read as light
    /// with soft gradients rather than hard per-cell seams. (Preview flips it.)
    static var smoothLight = true

    /// A contrast-gated edge-AA pass over the 3-D view — softens the chunky
    /// wall/floor/object edges while leaving flat texture interiors alone.
    static var worldAA = true

    /// Clamp-to-edge fetch of the baked cell light colour.
    @inline(__always) private func lc(_ map: GameMap, _ i: Int, _ j: Int) -> SIMD3<Float> {
        let x = min(max(i, 0), map.w - 1), y = min(max(j, 0), map.h - 1)
        return map.lightColor[map.idx(x, y)]
    }

    /// Bilinear light colour at a continuous world point (cell centres sit at
    /// integer+0.5, so the sample grid is shifted half a cell).
    @inline(__always) private func lightAt(_ map: GameMap, _ wx: Float, _ wy: Float) -> SIMD3<Float> {
        let gx = wx - 0.5, gy = wy - 0.5
        let x0 = Int(floor(gx)), y0 = Int(floor(gy))
        let tx = gx - Float(x0), ty = gy - Float(y0)
        let top = lc(map, x0, y0) + (lc(map, x0 + 1, y0) - lc(map, x0, y0)) * tx
        let bot = lc(map, x0, y0 + 1) + (lc(map, x0 + 1, y0 + 1) - lc(map, x0, y0 + 1)) * tx
        return top + (bot - top) * ty
    }

    private struct Renderable { let dist: Float; let kind: Int; let index: Int }

    // ── dynamic lights (muzzle flash + projectiles in flight) ───────────────────
    // Added at render time on top of the baked field, each with its own quadratic
    // distance falloff (no occlusion — they're transient and read fine without).
    private struct DynLight { let x, y, cr, cg, cb, r2inv, inten: Float }

    private func gatherLights(_ world: World) -> [DynLight] {
        var out: [DynLight] = []
        let p = world.player
        if p.muzzle > 0 {                                   // a bright warm flash at the barrel
            let mz = min(1, p.muzzle / 0.07)
            out.append(DynLight(x: p.pos.x, y: p.pos.y, cr: 1.0, cg: 0.86, cb: 0.55, r2inv: 1 / (6.5 * 6.5), inten: 1.7 * mz))
        }
        for pr in world.projectiles {                       // each bolt/ball glows on its surroundings
            let c: (Float, Float, Float), rad: Float, it: Float
            switch pr.kind {
            case .plasma:   c = (0.50, 0.85, 1.00); rad = 3.6; it = 1.0
            case .rocket:   c = (1.00, 0.70, 0.40); rad = 3.0; it = 0.8
            case .bolt:     c = (1.00, 0.85, 0.40); rad = 3.0; it = 0.9
            case .fireball: c = (1.00, 0.45, 0.18); rad = 4.0; it = 1.2
            case .bfgBall:  c = (0.50, 1.00, 0.45); rad = 5.5; it = 1.6
            }
            out.append(DynLight(x: pr.pos.x, y: pr.pos.y, cr: c.0, cg: c.1, cb: c.2, r2inv: 1 / (rad * rad), inten: it))
        }
        return out
    }

    /// Summed dynamic-light contribution at a world point (added to the baked light).
    @inline(__always) private func dynAt(_ lights: [DynLight], _ wx: Float, _ wy: Float) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        for L in lights {
            let dx = L.x - wx, dy = L.y - wy
            let f = 1 - (dx * dx + dy * dy) * L.r2inv
            if f > 0 { let w = L.inten * f * f; r += L.cr * w; g += L.cg * w; b += L.cb * w }
        }
        return (r, g, b)
    }

    /// A forward beam, premultiplied by its auto-gain, ready to sample per point.
    private struct Headlamp {
        let x, y, dx, dy: Float    // origin + unit facing
        let reach, nearReach: Float
        let cosInner, cosOuter: Float
        let cr, cg, cb: Float      // beam colour × gain
    }

    /// Build the headlamp for this frame: gain ramps with how dark the cell the
    /// marine stands in actually is, so the beam is invisible in bright rooms and
    /// does the seeing in the unlit ones.
    private func makeHeadlamp(_ world: World, _ dirX: Float, _ dirY: Float) -> Headlamp {
        let p = world.player
        let amb = lightAt(world.map, p.pos.x, p.pos.y)
        let luma = amb.x * 0.299 + amb.y * 0.587 + amb.z * 0.114
        let darkness = max(0, min(1, (lampLitRef - luma) / (lampLitRef - lampDarkRef)))
        let gain = lampGainFloor + (1 - lampGainFloor) * darkness
        let c = Raycaster.lampColor * (lampPeak * gain)
        return Headlamp(x: p.pos.x, y: p.pos.y, dx: dirX, dy: dirY,
                        reach: lampReach, nearReach: lampNear,
                        cosInner: lampCosInner, cosOuter: lampCosOuter,
                        cr: c.x, cg: c.y, cb: c.z)
    }

    /// Headlamp contribution (additive RGB) at a world point: a soft forward cone
    /// with quadratic distance falloff, plus a small omnidirectional feet-spill so
    /// the marine's immediate surroundings aren't pitch black off-axis.
    @inline(__always) private func hlAt(_ hl: Headlamp, _ wx: Float, _ wy: Float) -> (Float, Float, Float) {
        let dx = wx - hl.x, dy = wy - hl.y
        let d2 = dx * dx + dy * dy
        if d2 >= hl.reach * hl.reach { return (0, 0, 0) }
        let d = d2.squareRoot()
        let inv = d > 1e-4 ? 1 / d : 0
        let cosA = (dx * inv) * hl.dx + (dy * inv) * hl.dy
        var cone: Float = 0
        if cosA > hl.cosOuter {
            let s = min(1, (cosA - hl.cosOuter) / (hl.cosInner - hl.cosOuter))
            cone = s * s * (3 - 2 * s)                 // smoothstep — soft cone edge
        }
        let distF = 1 - d / hl.reach
        let near = d < hl.nearReach ? (1 - d / hl.nearReach) : 0
        let w = cone * distF * distF + 0.4 * near * near
        return (hl.cr * w, hl.cg * w, hl.cb * w)
    }

    func render(_ world: World, into c: Canvas2D) {
        let p = world.player
        let lights = Raycaster.colored ? gatherLights(world) : []
        let hasDyn = !lights.isEmpty
        let dirX = cos(p.dir), dirY = sin(p.dir)
        let planeX = -sin(p.dir) * RenderConfig.cameraPlane
        let planeY = cos(p.dir) * RenderConfig.cameraPlane
        let hl = Raycaster.colored ? makeHeadlamp(world, dirX, dirY) : nil
        let tex = Textures.shared
        let map = world.map
        let posZ = Float(viewH) * 0.5
        let fb = c.framebuffer
        let W = viewW
        let t = world.elapsed
        let flick: Float = 1 + 0.035 * sinf(t * 8.7) + 0.025 * sinf(t * 21.3 + 1.7)
        let texSize = tex.size

        c.resetZ()

        // ── floor & ceiling ──
        for y in 0..<viewH {
            let isFloor = y > horizon
            let pRow = isFloor ? (y - horizon) : (horizon - y)
            if pRow == 0 { continue }
            let rowDist = posZ / Float(pRow)
            let rowVis = ambient + glow * expf(-rowDist * falloff) * flick
            let stepX = rowDist * 2 * planeX / Float(W)
            let stepY = rowDist * 2 * planeY / Float(W)
            var floorX = p.pos.x + rowDist * (dirX - planeX)
            var floorY = p.pos.y + rowDist * (dirY - planeY)
            let rowBase = y * W
            for x in 0..<W {
                let cx = Int(floorX), cy = Int(floorY)
                let inB = map.inBounds(cx, cy)
                let i = inB ? map.idx(cx, cy) : 0
                let flatId = inB ? (isFloor ? map.floor[i] : map.ceil[i])
                                 : (isFloor ? FlatTex.concrete.rawValue : FlatTex.ceilDark.rawValue)
                var sxx = Int(floorX * Float(texSize)), syy = Int(floorY * Float(texSize))
                var shim: Float = 1
                if isFloor && (flatId == FlatTex.nukage.rawValue || flatId == FlatTex.blood.rawValue) {
                    // flowing warp + brightness shimmer so the pool reads as liquid
                    sxx += Int((sinf(floorX * 2.4 + t * 1.7) + sinf(floorY * 2.2 - t * 1.2)) * 3)
                    syy += Int((cosf(floorX * 2.0 - t * 1.4) + sinf(floorY * 2.6 + t * 1.1)) * 3)
                    shim = 1 + 0.22 * sinf(floorX * 3.5 + floorY * 3.5 + t * 3.2)
                }
                let texel = tex.flat(flatId).at(sxx & (texSize - 1), syy & (texSize - 1))
                let vis = rowVis * shim
                let dth = dither(x, y) * 0.05
                if Raycaster.colored {
                    let cc = Raycaster.smoothLight ? lightAt(map, floorX, floorY)
                                                   : (inB ? map.lightColor[i] : SIMD3<Float>(0.5, 0.5, 0.5))
                    var lr = cc.x * vis + dth, lg = cc.y * vis + dth, lb = cc.z * vis + dth
                    if hasDyn { let d = dynAt(lights, floorX, floorY); lr += d.0; lg += d.1; lb += d.2 }
                    if let hl = hl { let h = hlAt(hl, floorX, floorY); lr += h.0; lg += h.1; lb += h.2 }
                    fb[rowBase + x] = shadeRGB(texel, max(0.03, lr), max(0.03, lg), max(0.03, lb))
                } else {
                    let cellLight = inB ? map.light[i] : 0.5
                    fb[rowBase + x] = shade(texel, max(0.03, cellLight * vis + dth))
                }
                floorX += stepX; floorY += stepY
            }
        }

        // draws one full-height textured wall column. `doorShift` > 0 marks a
        // sliding-door panel: the along-wall texture coordinate is pushed toward
        // the nearest jamb by that fraction, so the two panels read as retracting
        // sideways into the frame (centre-split) rather than rising out of sight.
        func drawWallColumn(_ x: Int, _ rx: Float, _ ry: Float, _ texId: Int, _ dist: Float,
                            _ side: Int, _ mx: Int, _ my: Int, _ doorShift: Float) {
            let lh = Int(Float(viewH) / dist)
            let ds = -lh / 2 + horizon, de = lh / 2 + horizon
            let hitU = side == 0 ? (p.pos.y + dist * ry) : (p.pos.x + dist * rx)
            var wallX = hitU - floor(hitU)
            if doorShift > 0 { wallX += wallX < 0.5 ? doorShift : -doorShift }   // each half slides to its jamb
            var tX = Int(wallX * Float(texSize))
            if side == 0 && rx > 0 { tX = texSize - tX - 1 }
            if side == 1 && ry < 0 { tX = texSize - tX - 1 }
            tX = max(0, min(texSize - 1, tX))
            let inB = map.inBounds(mx, my)
            let sd: Float = side == 1 ? 0.74 : 1.0
            let cv = (ambient + glow * expf(-dist * falloff) * flick) * sd
            let cl = inB ? map.light[map.idx(mx, my)] : 0.6
            // wall-face light, interpolated ALONG the wall's run so long walls
            // fade smoothly instead of stepping cell-to-cell.
            let cc: SIMD3<Float>
            if Raycaster.smoothLight {
                let g = hitU - 0.5
                let k0 = Int(floor(g)); let tk = g - Float(k0)
                let a = side == 0 ? lc(map, mx, k0)     : lc(map, k0, my)
                let b = side == 0 ? lc(map, mx, k0 + 1) : lc(map, k0 + 1, my)
                cc = a + (b - a) * tk
            } else {
                cc = inB ? map.lightColor[map.idx(mx, my)] : SIMD3<Float>(0.6, 0.6, 0.6)
            }
            let wt = tex.wall(texId)
            // dynamic light + headlamp are constant down the column (one wall point)
            var dynR: Float = 0, dynG: Float = 0, dynB: Float = 0
            if hasDyn || hl != nil {
                let wwx = side == 0 ? Float(mx) + 0.5 : hitU
                let wwy = side == 0 ? hitU : Float(my) + 0.5
                if hasDyn { let d = dynAt(lights, wwx, wwy); dynR = d.0; dynG = d.1; dynB = d.2 }
                if let hl = hl { let h = hlAt(hl, wwx, wwy); dynR += h.0; dynG += h.1; dynB += h.2 }
            }
            // a sliding-door panel is full-height (it parts sideways, not upward)
            let y0 = max(0, ds), y1 = min(viewH - 1, de)
            if y1 < y0 { return }
            let invH = Float(texSize) / Float(lh)
            var rb = y0 * W + x
            for y in y0...y1 {
                let tY = min(texSize - 1, max(0, Int(Float(y - ds) * invH)))
                let dth = dither(x, y) * 0.05
                if Raycaster.colored {
                    fb[rb] = shadeRGB(wt.at(tX, tY), max(0.03, cc.x * cv + dynR + dth),
                                      max(0.03, cc.y * cv + dynG + dth), max(0.03, cc.z * cv + dynB + dth))
                } else {
                    fb[rb] = shade(wt.at(tX, tY), max(0.03, cl * cv + dth))
                }
                rb += W
            }
        }

        // ── walls (with centre-split sliding doors) ──
        for x in 0..<W {
            let cameraX = 2 * Float(x) / Float(W) - 1
            let rayX = dirX + planeX * cameraX
            let rayY = dirY + planeY * cameraX
            var mapX = Int(p.pos.x), mapY = Int(p.pos.y)
            let deltaX = rayX == 0 ? 1e30 : abs(1 / rayX)
            let deltaY = rayY == 0 ? 1e30 : abs(1 / rayY)
            var stepX = 0, stepY = 0
            var sideX: Float = 0, sideY: Float = 0
            if rayX < 0 { stepX = -1; sideX = (p.pos.x - Float(mapX)) * deltaX } else { stepX = 1; sideX = (Float(mapX) + 1 - p.pos.x) * deltaX }
            if rayY < 0 { stepY = -1; sideY = (p.pos.y - Float(mapY)) * deltaY } else { stepY = 1; sideY = (Float(mapY) + 1 - p.pos.y) * deltaY }

            var side = 0
            var wallTexId = 0, wallMapX = mapX, wallMapY = mapY
            var doorShift: Float = 0                          // >0 ⇒ the hit is a sliding-door panel
            var iterations = 0
            while iterations < 256 {
                iterations += 1
                if sideX < sideY { sideX += deltaX; mapX += stepX; side = 0 } else { sideY += deltaY; mapY += stepY; side = 1 }
                let id = map.wallAt(mapX, mapY)
                if id == 0 { continue }
                if map.inBounds(mapX, mapY), let d = map.doors[map.idx(mapX, mapY)] {
                    if d.open >= GameMap.passThreshold { continue }   // fully retracted into the frame
                    // centre-split door: find where this ray crosses the door plane.
                    // The central slit (widening as it opens) is see-through; the two
                    // panels to either side are solid, full-height occluders.
                    let dd = max(0.0001, side == 0 ? (sideX - deltaX) : (sideY - deltaY))
                    let hu = side == 0 ? (p.pos.y + dd * rayY) : (p.pos.x + dd * rayX)
                    let wx = hu - floor(hu)
                    let s = 0.5 * min(1, d.open / GameMap.passThreshold)   // half-gap; panels fully part at passThreshold
                    if abs(wx - 0.5) < s { continue }                      // through the slit — room behind shows
                    wallTexId = id; wallMapX = mapX; wallMapY = mapY; doorShift = s; break   // a solid panel
                }
                wallTexId = id; wallMapX = mapX; wallMapY = mapY; break
            }
            // panels break the DDA like walls, so the break distance is the nearest
            // blocker for sprite occlusion (the slit lets sprites behind show through).
            let dist = max(0.0001, side == 0 ? (sideX - deltaX) : (sideY - deltaY))
            c.zbuffer[x] = dist
            if wallTexId != 0 { drawWallColumn(x, rayX, rayY, wallTexId, dist, side, wallMapX, wallMapY, doorShift) }
        }

        drawThings(world, into: c, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY, flick: flick,
                   lights: lights, hasDyn: hasDyn, headlamp: hl)

        if Raycaster.worldAA { applyWorldAA(c) }
    }

    /// Edge-aware softening of the 3-D view (rows 0..<viewH; the HUD draws after
    /// and is untouched). Each pixel blends toward its 4-neighbour average in
    /// proportion to local contrast, so only edges soften — flat texture stays.
    private func applyWorldAA(_ c: Canvas2D) {
        let W = viewW, H = viewH, n = W * H
        let fb = c.framebuffer
        let src = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        src.update(from: fb, count: n)
        defer { src.deallocate() }
        let thr = 84                                  // contrast gate (sum of channels)
        for y in 1..<(H - 1) {
            let row = y * W
            for x in 1..<(W - 1) {
                let i = row + x
                let c0 = src[i], n4 = src[i - W], s4 = src[i + W], e4 = src[i - 1], w4 = src[i + 1]
                let ar = (Int(n4 & 0xFF) + Int(s4 & 0xFF) + Int(e4 & 0xFF) + Int(w4 & 0xFF)) >> 2
                let ag = (Int((n4 >> 8) & 0xFF) + Int((s4 >> 8) & 0xFF) + Int((e4 >> 8) & 0xFF) + Int((w4 >> 8) & 0xFF)) >> 2
                let ab = (Int((n4 >> 16) & 0xFF) + Int((s4 >> 16) & 0xFF) + Int((e4 >> 16) & 0xFF) + Int((w4 >> 16) & 0xFF)) >> 2
                let lc = Int(c0 & 0xFF) + Int((c0 >> 8) & 0xFF) + Int((c0 >> 16) & 0xFF)
                let contrast = abs(lc - (ar + ag + ab))
                if contrast <= thr { continue }
                let wgt = min(0.7, Float(contrast - thr) / 200)   // stronger at sharper edges
                let iw = 1 - wgt
                fb[i] = packRGBA(Int(Float(c0 & 0xFF) * iw + Float(ar) * wgt),
                                 Int(Float((c0 >> 8) & 0xFF) * iw + Float(ag) * wgt),
                                 Int(Float((c0 >> 16) & 0xFF) * iw + Float(ab) * wgt), 255)
            }
        }
    }

    private func brightness(_ d: Float, _ flick: Float) -> Float {
        max(0.05, ambient + glow * expf(-d * falloff) * flick)
    }

    /// GPU-renderer overlay: the SDF kernel draws the world + creatures, but
    /// items / projectiles / particles are still sprites. Fill the z-buffer from
    /// the walls (depth-only DDA) so they occlude correctly, then draw them.
    func overlayThings(_ world: World, into c: Canvas2D, depth: UnsafePointer<Float>? = nil, includeProjectiles: Bool = true) {
        let p = world.player
        let dirX = cos(p.dir), dirY = sin(p.dir)
        let planeX = -sin(p.dir) * RenderConfig.cameraPlane
        let planeY = cos(p.dir) * RenderConfig.cameraPlane
        let map = world.map
        let W = viewW
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
        let t = world.elapsed
        let flick: Float = 1 + 0.035 * sinf(t * 8.7) + 0.025 * sinf(t * 21.3 + 1.7)
        let lights = Raycaster.colored ? gatherLights(world) : []
        let hl = Raycaster.colored ? makeHeadlamp(world, dirX, dirY) : nil
        drawThings(world, into: c, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY,
                   flick: flick, lights: lights, hasDyn: !lights.isEmpty, headlamp: hl,
                   includeMonsters: false, includeItems: false,
                   includeProjectiles: includeProjectiles, depthBuf: depth)   // monsters/items/projectiles are SDF on the GPU path
    }

    private func drawThings(_ world: World, into c: Canvas2D, dirX: Float, dirY: Float,
                            planeX: Float, planeY: Float, flick: Float, lights: [DynLight], hasDyn: Bool,
                            headlamp: Headlamp? = nil,
                            includeMonsters: Bool = true, includeItems: Bool = true,
                            includeProjectiles: Bool = true,
                            depthBuf: UnsafePointer<Float>? = nil) {
        let p = world.player
        let sprites = Sprites.shared
        var things: [Renderable] = []
        if includeMonsters { for (i, m) in world.monsters.enumerated() { things.append(Renderable(dist: vlen(m.pos - p.pos), kind: 0, index: i)) } }
        if includeItems { for (i, it) in world.items.enumerated() where !it.taken { things.append(Renderable(dist: vlen(it.pos - p.pos), kind: 1, index: i)) } }
        if includeProjectiles { for (i, pr) in world.projectiles.enumerated() { things.append(Renderable(dist: vlen(pr.pos - p.pos), kind: 2, index: i)) } }
        // world props (drums + deployed mines) — always drawn as sprites, on both
        // the CPU and the GPU-overlay path (they have no SDF on the kernel)
        for (i, d) in world.drums.enumerated() { things.append(Renderable(dist: vlen(d.pos - p.pos), kind: 4, index: i)) }
        for (i, mn) in world.deployedMines.enumerated() { things.append(Renderable(dist: vlen(mn.pos - p.pos), kind: 5, index: i)) }
        for i in world.particles.indices { things.append(Renderable(dist: vlen(world.particles[i].pos - p.pos), kind: 3, index: i)) }
        things.sort { $0.dist > $1.dist }

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
            case 0:
                let m = world.monsters[thing.index]
                let ms = sprites.monster(m.kind)
                // 8-rotation view: 0 = facing the player (front), 4 = back
                let toP = atan2(p.pos.y - m.pos.y, p.pos.x - m.pos.x)
                var rel = m.dir - toP
                rel -= (2 * Float.pi) * floor(rel / (2 * Float.pi))
                let bucket = Int((rel / (2 * Float.pi) * 8).rounded()) % 8
                switch m.state {
                case .dead: spr = ms.death[1][bucket]
                case .dying: spr = (m.stateTime < 0.22 ? ms.death[0] : ms.death[1])[bucket]
                case .attack: spr = ms.attack[bucket]
                default: spr = ms.walk[Int(m.animTime * 4) % 2][bucket]
                }
                pos = m.pos
                billboardH = m.def.billboardH
                if m.painFlash > 0 { tint = packRGBA(255, 235, 225); tintAmt = 0.65 }
                if m.def.flying && m.alive { vBias = 0.34 }
                if !m.alive {
                    groundFade = true                          // soft floor contact (no hard blood edge)
                    let cxi = Int(m.pos.x), cyi = Int(m.pos.y)
                    if world.map.inBounds(cxi, cyi),
                       world.map.floor[world.map.idx(cxi, cyi)] == FlatTex.nukage.rawValue {
                        dissolve = min(1, m.stateTime * 0.5)   // also eaten by toxic waste, over ~2s
                    }
                }
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
            default:
                drawParticle(world.particles[thing.index], into: c, p: p, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY, invDet: invDet)
                continue
            }

            let rel = pos - p.pos
            let tX = invDet * (dirY * rel.x - dirX * rel.y)
            let tY = invDet * (-planeY * rel.x + planeX * rel.y)
            if tY <= 0.12 { continue }
            let lightB = emissive ? 1.0 : brightness(tY, flick)
            // a thing sits IN the local light colour — a creature in green nukage
            // glow reads green, like the walls around it. Emissive things ignore it.
            var lightCol = SIMD3<Float>(1, 1, 1)
            var dyn = (Float(0), Float(0), Float(0))
            if Raycaster.colored && !emissive {
                if Raycaster.smoothLight {
                    lightCol = lightAt(world.map, pos.x, pos.y)
                } else {
                    let mcx = Int(pos.x), mcy = Int(pos.y)
                    if world.map.inBounds(mcx, mcy) { lightCol = world.map.lightColor[world.map.idx(mcx, mcy)] }
                }
                if hasDyn { dyn = dynAt(lights, pos.x, pos.y) }   // muzzle flash / fireball lights the creature
                // the headlamp picks the thing out of the dark — you see the alien
                // when your beam falls on it (and not a moment before)
                if let hl = headlamp { let h = hlAt(hl, pos.x, pos.y); dyn.0 += h.0; dyn.1 += h.1; dyn.2 += h.2 }
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
        let lineFull = Float(viewH) / transformY
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

    private func drawParticle(_ pa: Particle, into c: Canvas2D, p: Player,
                              dirX: Float, dirY: Float, planeX: Float, planeY: Float, invDet: Float) {
        let rel = pa.pos - p.pos
        let tX = invDet * (dirY * rel.x - dirX * rel.y)
        let tY = invDet * (-planeY * rel.x + planeX * rel.y)
        if tY <= 0.15 { return }
        let W = viewW
        let lineFull = Float(viewH) / tY
        let screenX = Int(Float(W) / 2 * (1 + tX / tY))
        let screenY = horizon + Int(lineFull * 0.5) - Int(lineFull * pa.height)
        if screenX < 0 || screenX >= W || tY >= c.zbuffer[screenX] { return }
        let r = max(1, Int(lineFull * 0.05 * pa.size))
        let lifeF = max(0, min(1, pa.life / pa.maxLife))
        if pa.fire {
            if pa.color == 0 {
                // flame: soft additive glow, age-ramped white-hot → orange → deep
                // red → smoke (overlapping tongues build a body of flame)
                let age = 1 - lifeF
                let col: UInt32
                if age < 0.25 { col = mixRGBA(packRGBA(255, 250, 210), packRGBA(255, 196, 70), age / 0.25) }
                else if age < 0.6 { col = mixRGBA(packRGBA(255, 196, 70), packRGBA(232, 96, 26), (age - 0.25) / 0.35) }
                else { col = mixRGBA(packRGBA(232, 96, 26), packRGBA(60, 46, 44), (age - 0.6) / 0.4) }
                let glow = (1 - age) * pa.maxAlpha
                for oy in -r...r { for ox in -r...r {
                    let d2 = ox * ox + oy * oy
                    if d2 > r * r { continue }
                    let fall = 1 - Float(d2).squareRoot() / Float(r)
                    c.blendAdd(screenX + ox, screenY + oy, col, glow * fall * fall)
                }}
            } else {
                // spark: a sharp, tiny, bright glint (1–2px, flat additive — NOT a
                // soft orb) with a short streak trailing its arc through the air
                let sa = lifeF * pa.maxAlpha
                let sr = min(2, r)
                for oy in -sr...sr { for ox in -sr...sr {
                    if ox * ox + oy * oy > sr * sr + 1 { continue }
                    c.blendAdd(screenX + ox, screenY + oy, pa.color, sa)
                }}
                c.blendAdd(screenX, screenY - sr - 1, pa.color, sa * 0.5)        // short trail
                c.blendAdd(screenX, screenY - sr - 2, pa.color, sa * 0.28)
            }
            return
        }
        let a = lifeF * pa.maxAlpha
        for oy in -r...r { for ox in -r...r {            // soft round puff (radial alpha falloff)
            let d2 = ox * ox + oy * oy
            if d2 > r * r { continue }
            let fall = 1 - Float(d2).squareRoot() / Float(r)
            c.blend(screenX + ox, screenY + oy, pa.color, a * fall * fall)
        }}
    }
}
