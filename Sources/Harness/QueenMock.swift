// Citadel — QUEEN billboard mock (CITADEL_QUEENMOCK). Dev-only R&D.
//
// Answers ONE question: if the queen were a flux-art BILLBOARD instead of a
// native SDF sculpt, how would she sit in the lair under the game's REAL
// environmental lighting?
//
// Pipeline:
//   1. Render the actual level-8 flooded-depths lair through the GPU raymarcher
//      (framebuffer + per-pixel PERPENDICULAR depth), environment only.
//   2. Key the flux plate to an RGBA cutout. The plate is a full composited scene
//      (dark void left, warm god-rays behind her, fog + water at the base), so a
//      naive luma key leaves a warm halo. We classify "background" as dark-void
//      OR smooth-and-dim (rays/fog/water read as low local detail), flood-fill it
//      from the edges, and crop to her silhouette. Her enclosed glowing ova
//      survive because the fill can't reach them through her detailed body.
//   3. Composite her as a depth-occluded billboard using the SAME WorldLight math
//      the shipping SpriteCompositor uses: a SINGLE-POINT distance falloff +
//      sector colour + headlamp reveal, applied to the whole sprite (form-light
//      is baked into the art — the honest billboard model). Emissive ova/eyes
//      ignore the darkness and burn amber.
//
// Writes cutout.png + beam / dark / firelit stills to ~/Desktop/Citadel-QueenMock.
// Never shipped (CITADEL_HARNESS-gated dispatch strips it from release).

import Foundation
import Cocoa
import simd
import Metal
import ImageIO

enum QueenMock {

    // ── cutout ────────────────────────────────────────────────────────────────
    struct Cutout { let px: [UInt32]; let w: Int; let h: Int; let alpha: [Float]; let emis: [Float] }

    @inline(__always) private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    static func loadCutout(_ path: String) -> Cutout? {
        guard let img = NSImage(contentsOf: URL(fileURLWithPath: path)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 0, height: 0)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt32](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        }

        // luma
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<w * h {
            let c = px[i]
            let r = Float(c & 0xFF), g = Float((c >> 8) & 0xFF), b = Float((c >> 16) & 0xFF)
            luma[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }

        // local detail (edge strength) — max luma gradient over the 8-neighbourhood
        var detail = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            let ax = abs(luma[i + 1] - luma[i - 1])
            let ay = abs(luma[i + w] - luma[i - w])
            let ad = abs(luma[i + w + 1] - luma[i - w - 1])
            let ae = abs(luma[i + w - 1] - luma[i - w + 1])
            detail[i] = max(max(ax, ay), 0.7 * max(ad, ae))
        } }

        // ── silhouette by morphology ────────────────────────────────────────────
        // Her body is DENSELY detailed (edges everywhere) or bright (ova/wet gold);
        // the god-rays / fog / water are dim AND smooth. Seed on detail-or-bright,
        // then dilate: her dense seeds fuse into ONE solid blob while sparse ray
        // specks stay small. Keep the largest connected component, erode back to a
        // tight silhouette, and fill interior holes so her dark smooth armour is
        // solid. This separates her from a backdrop that shares her tones.
        // Seed on STRONG edges only (amplitude well above film-grain noise, which
        // is high-frequency but low-amplitude). No bright-luma seed — that grabbed
        // the warm ray shaft; her ova are enclosed, so hole-filling solidifies them.
        let R = 13
        var fg = [Bool](repeating: false, count: w * h)
        for i in 0..<w * h { fg[i] = detail[i] > 0.13 }

        func dilate(_ src: [Bool]) -> [Bool] {
            var tmp = [Bool](repeating: false, count: w * h)
            for y in 0..<h { let base = y * w
                for x in 0..<w { let lo = max(0, x - R), hi = min(w - 1, x + R)
                    var v = false, k = lo; while k <= hi { if src[base + k] { v = true; break }; k += 1 }
                    tmp[base + x] = v } }
            var out = [Bool](repeating: false, count: w * h)
            for x in 0..<w { for y in 0..<h { let lo = max(0, y - R), hi = min(h - 1, y + R)
                var v = false, k = lo; while k <= hi { if tmp[k * w + x] { v = true; break }; k += 1 }
                out[y * w + x] = v } }
            return out
        }
        func erode(_ src: [Bool]) -> [Bool] {
            var tmp = [Bool](repeating: false, count: w * h)
            for y in 0..<h { let base = y * w
                for x in 0..<w { let lo = max(0, x - R), hi = min(w - 1, x + R)
                    var v = true, k = lo; while k <= hi { if !src[base + k] { v = false; break }; k += 1 }
                    tmp[base + x] = v } }
            var out = [Bool](repeating: false, count: w * h)
            for x in 0..<w { for y in 0..<h { let lo = max(0, y - R), hi = min(h - 1, y + R)
                var v = true, k = lo; while k <= hi { if !tmp[k * w + x] { v = false; break }; k += 1 }
                out[y * w + x] = v } }
            return out
        }

        let dil = dilate(fg)

        // largest 4-connected component of the dilated mask
        var label = [Int32](repeating: -1, count: w * h)
        var sizes = [Int]()
        var q = [Int](); q.reserveCapacity(w * h / 2)
        for start in 0..<w * h {
            if !dil[start] || label[start] >= 0 { continue }
            let id = Int32(sizes.count); var cnt = 0
            q.removeAll(keepingCapacity: true); q.append(start); label[start] = id
            var qi = 0
            while qi < q.count { let i = q[qi]; qi += 1; cnt += 1
                let x = i % w, y = i / w
                if x > 0, dil[i - 1], label[i - 1] < 0 { label[i - 1] = id; q.append(i - 1) }
                if x < w - 1, dil[i + 1], label[i + 1] < 0 { label[i + 1] = id; q.append(i + 1) }
                if y > 0, dil[i - w], label[i - w] < 0 { label[i - w] = id; q.append(i - w) }
                if y < h - 1, dil[i + w], label[i + w] < 0 { label[i + w] = id; q.append(i + w) }
            }
            sizes.append(cnt)
        }
        if sizes.isEmpty { return nil }
        var maxId = 0; for k in 1..<sizes.count where sizes[k] > sizes[maxId] { maxId = k }
        var body = [Bool](repeating: false, count: w * h)
        for i in 0..<w * h { body[i] = label[i] == Int32(maxId) }

        let er = erode(body)

        // fill interior holes: everything NOT reachable from the border through
        // non-silhouette pixels is an enclosed hole → part of her
        var outside = [Bool](repeating: false, count: w * h)
        var qq = [Int](); qq.reserveCapacity(w * h / 2)
        @inline(__always) func seedO(_ i: Int) { if !er[i] && !outside[i] { outside[i] = true; qq.append(i) } }
        for x in 0..<w { seedO(x); seedO((h - 1) * w + x) }
        for y in 0..<h { seedO(y * w); seedO(y * w + w - 1) }
        var qi = 0
        while qi < qq.count { let i = qq[qi]; qi += 1; let x = i % w, y = i / w
            if x > 0 { seedO(i - 1) }; if x < w - 1 { seedO(i + 1) }
            if y > 0 { seedO(i - w) }; if y < h - 1 { seedO(i + w) } }
        var alpha = [Float](repeating: 0, count: w * h)
        for i in 0..<w * h { alpha[i] = outside[i] ? 0 : 1 }

        // one 3×3 box-blur pass to feather the 1-px silhouette edge
        var af = alpha
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            var s: Float = 0
            s += alpha[i - w - 1] + alpha[i - w] + alpha[i - w + 1]
            s += alpha[i - 1]     + alpha[i]     + alpha[i + 1]
            s += alpha[i + w - 1] + alpha[i + w] + alpha[i + w + 1]
            af[i] = s / 9
        } }
        alpha = af

        // emissive mask: warm + bright interior (the ova + eyes)
        var emis = [Float](repeating: 0, count: w * h)
        for i in 0..<w * h where alpha[i] > 0.5 {
            let c = px[i]
            let r = Float(c & 0xFF) / 255, g = Float((c >> 8) & 0xFF) / 255, b = Float((c >> 16) & 0xFF) / 255
            let warm = max(0, r - b)
            let val = max(r, max(g, b))
            emis[i] = smoothstep(0.28, 0.58, warm) * smoothstep(0.52, 0.86, val)
        }

        // crop to her bounding box (+padding) so the billboard centres on her,
        // not on the wide empty void to her left
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 0.5 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        } }
        if maxX < minX || maxY < minY { return nil }
        // trim the bottom band (the water reflection keys into a ragged edge)
        maxY = minY + Int(Float(maxY - minY) * 0.92)
        let pad = 6
        minX = max(0, minX - pad); minY = max(0, minY - pad)
        maxX = min(w - 1, maxX + pad); maxY = min(h - 1, maxY + pad)
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        var cpx = [UInt32](repeating: 0, count: cw * ch)
        var cal = [Float](repeating: 0, count: cw * ch)
        var cem = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw {
            let si = (minY + y) * w + (minX + x), di = y * cw + x
            cpx[di] = px[si]; cal[di] = alpha[si]; cem[di] = emis[si]
        } }
        return Cutout(px: cpx, w: cw, h: ch, alpha: cal, emis: cem)
    }

    // ── lair render (env only) ─────────────────────────────────────────────────
    struct Plate { let fb: [UInt32]; let depth: [Float]; let world: World
                   let camPos: SIMD2<Float>; let camDir: Float; let W: Int; let H: Int }

    static func renderLair(level: Int) -> Plate? {
        guard let device = MTLCreateSystemDefaultDevice() else { print("Citadel: no Metal device"); return nil }
        let W = RenderConfig.width, H = RenderConfig.viewHeight
        let queue = device.makeCommandQueue()!
        guard let (pipe, post) = GPURaymarch.makePipelines(device) else { print("Citadel: kernel build failed"); return nil }
        guard let wallArr = GPURaymarch.makeTextureArray(device, Textures.shared.walls),
              let flatArr = GPURaymarch.makeTextureArray(device, Textures.shared.flats) else { return nil }

        let world = World(level: level, colonyIndex: level - 1, seed: 1234 &+ UInt64(level))
        let map = world.map
        let (df, sw, sh) = GPURaymarch.buildDistanceField(map)
        let elights = Lighting.pointLights(map)

        let dtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: sw, height: sh, mipmapped: false)
        dtDesc.usage = .shaderRead; dtDesc.storageMode = .shared
        let dtTex = device.makeTexture(descriptor: dtDesc)!
        df.withUnsafeBytes { dtTex.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 8) }

        var lc = [SIMD4<Float>](repeating: .zero, count: map.w * map.h)
        for k in 0..<lc.count { let c = map.lightColor[k]; lc[k] = SIMD4(c.x, c.y, c.z, 1) }
        let liDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: map.w, height: map.h, mipmapped: false)
        liDesc.usage = .shaderRead; liDesc.storageMode = .shared
        let liTex = device.makeTexture(descriptor: liDesc)!
        lc.withUnsafeBytes { liTex.replace(region: MTLRegionMake2D(0, 0, map.w, map.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: map.w * 16) }

        let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
        hdrDesc.usage = [.shaderWrite, .shaderRead]; hdrDesc.storageMode = .private
        let hdrTex = device.makeTexture(descriptor: hdrDesc)!
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        outDesc.usage = [.shaderWrite, .shaderRead]; outDesc.storageMode = .shared
        let outTex = device.makeTexture(descriptor: outDesc)!
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
        depthDesc.usage = [.shaderWrite, .shaderRead]; depthDesc.storageMode = .shared   // .shared so we can read it back
        let depthTex = device.makeTexture(descriptor: depthDesc)!

        let wallIdT = GPURaymarch.makeIdTexture(device, map.wall, map.w, map.h)
        let floorIdT = GPURaymarch.makeIdTexture(device, map.floor, map.w, map.h)
        let ceilIdT = GPURaymarch.makeIdTexture(device, map.ceil, map.w, map.h)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1)

        var fits = map.pipeFittings
        let nFits = fits.count
        if fits.isEmpty { fits = [SIMD4<Float>(0, 0, 0, 0)] }

        // camera: down the longest corridor if there is one, else the spawn view
        let camPos: SIMD2<Float>, camDir: Float
        if let cor = GPURaymarch.bestCorridorView(map) { camPos = cor.pos; camDir = cor.dir }
        else { camPos = world.player.pos; camDir = world.player.dir }

        let dx = cos(camDir), dy = sin(camDir), plane = RenderConfig.cameraPlane
        let (lights0, shadow) = GPURaymarch.packLights(elights, camera: camPos)
        let lights = lights0.isEmpty ? [GPURaymarch.GPULight(posR: .zero, colI: .zero)] : lights0
        var u = GPURaymarch.Uniforms(
            ro: SIMD4(camPos.x, 0.5, camPos.y, 2.3),
            fwd: SIMD4(dx, 0, dy, 0),
            right: SIMD4(-sin(camDir) * plane, 0, cos(camDir) * plane, 0),
            up: SIMD4(0, 1, 0, 0),
            params: SIMD4(Float(W), Float(H), Float(RenderConfig.horizon), 3.2),   // tall lair ceiling so the boss fits
            grid: SIMD4(Float(map.w), Float(map.h), 0, Float(lights0.count)),   // 0 creatures
            extra: SIMD4(0, Lighting.floodLevel(level: level), Float(shadow), 0))
        u.vmB.w = Float(nFits)

        let nilMon = device.makeBuffer(bytes: [GPURaymarch.GMonster(a: .zero, b: .zero, c: .zero)], length: MemoryLayout<GPURaymarch.GMonster>.stride, options: .storageModeShared)!
        let nilShp = device.makeBuffer(bytes: [GPURaymarch.GShape(a: .zero, b: .zero, col: .zero)], length: MemoryLayout<GPURaymarch.GShape>.stride, options: .storageModeShared)!
        var dyn = lights, decals = [SIMD4<Float>(0, 0, 0, 0)]

        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipe)
        enc.setTexture(dtTex, index: 0); enc.setTexture(liTex, index: 1); enc.setTexture(hdrTex, index: 2)
        enc.setTexture(wallArr, index: 3); enc.setTexture(flatArr, index: 4)
        enc.setTexture(wallIdT, index: 5); enc.setTexture(floorIdT, index: 6); enc.setTexture(ceilIdT, index: 7)
        enc.setTexture(depthTex, index: 8)
        enc.setBytes(&u, length: MemoryLayout<GPURaymarch.Uniforms>.stride, index: 0)
        enc.setBytes(&dyn, length: MemoryLayout<GPURaymarch.GPULight>.stride * dyn.count, index: 1)
        enc.setBuffer(nilMon, offset: 0, index: 2); enc.setBuffer(nilShp, offset: 0, index: 3)
        enc.setBytes(&decals, length: MemoryLayout<SIMD4<Float>>.stride * decals.count, index: 4)
        enc.setBytes(&fits, length: MemoryLayout<SIMD4<Float>>.stride * fits.count, index: 6)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        let penc = cmd.makeComputeCommandEncoder()!
        penc.setComputePipelineState(post)
        penc.setTexture(hdrTex, index: 0); penc.setTexture(outTex, index: 1)
        penc.setBytes(&u, length: MemoryLayout<GPURaymarch.Uniforms>.stride, index: 0)
        penc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        penc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()

        var fb = [UInt32](repeating: 0, count: W * H)
        fb.withUnsafeMutableBytes { outTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
        var depth = [Float](repeating: 0, count: W * H)
        depth.withUnsafeMutableBytes { depthTex.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }

        return Plate(fb: fb, depth: depth, world: world, camPos: camPos, camDir: camDir, W: W, H: H)
    }

    // ── billboard composite (mirrors SpriteCompositor.drawSprite) ──────────────
    static func composite(into fb: inout [UInt32], depth: [Float], W: Int, H: Int,
                          world: World, camPos: SIMD2<Float>, camDir: Float,
                          cut: Cutout, qpos: SIMD2<Float>, billboardH: Float,
                          beam: Bool, firelit: Bool, fill: Float,
                          swayAmp: Float = 0, pulseAmp: Float = 0, breatheAmp: Float = 0, phase: Float = 0) {
        let dirX = cos(camDir), dirY = sin(camDir), plane = RenderConfig.cameraPlane
        let planeX = -sin(camDir) * plane, planeY = cos(camDir) * plane
        let invDet = 1 / (planeX * dirY - dirX * planeY)
        let rel = qpos - camPos
        let tX = invDet * (dirY * rel.x - dirX * rel.y)
        let tY = invDet * (-planeY * rel.x + planeX * rel.y)
        if tY <= 0.12 { return }

        // lighting sampled at her position ONLY, applied to the whole sprite
        let lightB = WorldLight.brightness(tY, 1.0)
        let lightCol = WorldLight.colored ? WorldLight.lightAt(world.map, qpos.x, qpos.y) : SIMD3<Float>(1, 1, 1)
        var dyn = (Float(0), Float(0), Float(0))
        if beam {
            // Hunting her in the pitch-dark depths → the auto-gain lamp is near
            // full. (makeHeadlamp ramps gain from the light at the player's cell;
            // this corridor mouth reads as semi-lit, so force the dark-hunt case.)
            let gain: Float = 0.95
            let lc = WorldLight.lampColor * (WorldLight.lampPeak * gain)
            let hl = WorldLight.Headlamp(x: camPos.x, y: camPos.y, dx: dirX, dy: dirY,
                                         reach: WorldLight.lampReach, nearReach: WorldLight.lampNear,
                                         cosInner: WorldLight.lampCosInner, cosOuter: WorldLight.lampCosOuter,
                                         cr: lc.x, cg: lc.y, cb: lc.z)
            dyn = WorldLight.hlAt(hl, qpos.x, qpos.y)
        }
        if firelit {   // a warm fireball flanking her, to show environmental colour pickup
            let L = [WorldLight.DynLight(x: qpos.x - 1.3, y: qpos.y + 0.4, cr: 1.0, cg: 0.5, cb: 0.18,
                                         r2inv: 1 / (4.5 * 4.5), inten: 1.9)]
            let d = WorldLight.dynAt(L, qpos.x, qpos.y)
            dyn.0 += d.0; dyn.1 += d.1; dyn.2 += d.2
        }

        let bscale = 1 + breatheAmp * sinf(phase)          // slow breathing squash/stretch
        let lineFull = Float(RenderConfig.projHeight) / tY
        let screenX = Int(Float(W) / 2 * (1 + tX / tY))
        let spriteH = Int(lineFull * billboardH * bscale)
        if spriteH < 1 { return }
        let spriteW = max(1, Int(Float(spriteH) * Float(cut.w) / Float(cut.h)))
        let bottom = RenderConfig.horizon + Int(lineFull * 0.5)
        let top = bottom - spriteH                          // feet anchored, top breathes
        let x0 = screenX - spriteW / 2

        for sx in 0..<spriteW {
            let col = x0 + sx
            if col < 0 || col >= W { continue }
            for sy in 0..<spriteH {
                let row = top + sy
                if row < 0 || row >= H { continue }
                if tY >= depth[row * W + col] { continue }   // per-pixel depth occlusion
                let rowFrac = Float(sy) / Float(spriteH)      // 0 crown … 1 tentacle base
                // tentacle sway: a travelling domain-warp that ramps toward the base,
                // so the crown holds still and the skirt undulates (not stiff spikes)
                var texXf = Float(sx) * Float(cut.w) / Float(spriteW)
                if swayAmp != 0 { texXf += swayAmp * smoothstep(0.42, 1.0, rowFrac) * sinf(phase + rowFrac * 7.0) }
                let texX = min(cut.w - 1, max(0, Int(texXf)))
                let texY = min(cut.h - 1, max(0, sy * cut.h / spriteH))
                let si = texY * cut.w + texX
                let a = cut.alpha[si]
                if a <= 0.004 { continue }
                let src = cut.px[si]
                // `fill` = a soft baked-in fill light (billboard best-practice) so
                // her dark-metal form is discernible; kept low on the dark shot.
                var lit = shadeRGB(src, fill + lightB * lightCol.x + dyn.0,
                                        fill + lightB * lightCol.y + dyn.1,
                                        fill + lightB * lightCol.z + dyn.2)
                var e = cut.emis[si]
                if pulseAmp != 0 { e *= max(0, 1 + pulseAmp * sinf(phase * 2 + Float(texY) * 0.012)) }  // ova heartbeat (throb travels up the clutch)
                if e > 0.01 {                                 // ova / eyes burn through the dark
                    let hot = shadeRGB(src, 1.15 + 0.5 * e, 1.0 + 0.2 * e, 0.85)
                    lit = mixRGBA(lit, hot, min(1, e))
                }
                let di = row * W + col
                fb[di] = a >= 0.999 ? lit : mixRGBA(fb[di], lit, a)
            }
        }
    }

    // ── output ────────────────────────────────────────────────────────────────
    static func writeFB(_ px: [UInt32], _ W: Int, _ H: Int, to url: URL) {
        var p = px
        p.withUnsafeMutableBufferPointer { Captures.writePNG($0.baseAddress!, w: W, h: H, scale: 1, to: url) }
    }

    static func writeGIF(_ frames: [[UInt32]], _ W: Int, _ H: Int, delay: Double, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let fileProps = [kCGImagePropertyGIFDictionary as String:
                         [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
                          [kCGImagePropertyGIFDelayTime as String: delay,
                           kCGImagePropertyGIFUnclampedDelayTime as String: delay]] as CFDictionary
        for f in frames {
            var px = f
            for i in 0..<px.count { px[i] |= 0xFF00_0000 }          // force opaque
            let cg: CGImage? = px.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                                          bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return ctx.makeImage()
            }
            if let cg = cg { CGImageDestinationAddImage(dest, cg, frameProps) }
        }
        _ = CGImageDestinationFinalize(dest)
    }

    static func writeCutoutDiag(_ cut: Cutout, to url: URL) {
        let mag = packRGBA(255, 0, 255)
        var out = [UInt32](repeating: mag, count: cut.w * cut.h)
        for i in 0..<cut.w * cut.h {
            let a = cut.alpha[i]
            if a > 0.004 { out[i] = a >= 0.999 ? cut.px[i] : mixRGBA(mag, cut.px[i], a) }
        }
        writeFB(out, cut.w, cut.h, to: url)
    }

    // ── entry ─────────────────────────────────────────────────────────────────
    static func run(src: String?, outDir: String?) {
        let srcPath = src ?? (NSHomeDirectory() + "/Downloads/original-biomechanical-pro-1238329892.png")
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-QueenMock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let cut = loadCutout(srcPath) else { print("Citadel: queen mock — couldn't key \(srcPath)"); return }
        writeCutoutDiag(cut, to: dir.appendingPathComponent("cutout.png"))
        print("  keyed cutout \(cut.w)×\(cut.h)")

        guard let plate = renderLair(level: 8) else { print("Citadel: queen mock — lair render failed"); return }
        let fwd = SIMD2<Float>(cos(plate.camDir), sin(plate.camDir))
        let qpos = plate.camPos + fwd * 2.8
        plate.world.player.pos = plate.camPos     // headlamp samples from here
        plate.world.player.dir = plate.camDir

        func shot(_ name: String, beam: Bool, firelit: Bool, fill: Float) {
            var fb = plate.fb
            composite(into: &fb, depth: plate.depth, W: plate.W, H: plate.H,
                      world: plate.world, camPos: plate.camPos, camDir: plate.camDir,
                      cut: cut, qpos: qpos, billboardH: 2.2, beam: beam, firelit: firelit, fill: fill)
            writeFB(fb, plate.W, plate.H, to: dir.appendingPathComponent(name))
        }
        shot("queen-lair-beam.png", beam: true, firelit: false, fill: 0.15)    // headlamp reveal
        shot("queen-lair-dark.png", beam: false, firelit: false, fill: 0.04)   // receded into the dark
        shot("queen-lair-firelit.png", beam: true, firelit: true, fill: 0.07)  // warm dynamic light picks her up

        // ── animated: procedural life from the ONE cutout ────────────────────────
        // ova heartbeat + tentacle sway + breathing, seamless loop. No extra art —
        // this is the on-brand path to animating a billboard boss (flux can't give
        // consistent frames). Written as a GIF so it Quick-Looks straight away.
        let N = 28
        var frames: [[UInt32]] = []
        for f in 0..<N {
            let phase = 2 * Float.pi * Float(f) / Float(N)
            var fb = plate.fb
            composite(into: &fb, depth: plate.depth, W: plate.W, H: plate.H,
                      world: plate.world, camPos: plate.camPos, camDir: plate.camDir,
                      cut: cut, qpos: qpos, billboardH: 2.2, beam: true, firelit: true, fill: 0.12,
                      swayAmp: 22, pulseAmp: 0.55, breatheAmp: 0.02, phase: phase)
            frames.append(fb)
        }
        writeGIF(frames, plate.W, plate.H, delay: 0.06, to: dir.appendingPathComponent("queen-lair-anim.gif"))
        writeFB(frames[0], plate.W, plate.H, to: dir.appendingPathComponent("anim-f00.png"))
        writeFB(frames[N / 3], plate.W, plate.H, to: dir.appendingPathComponent("anim-f09.png"))
        writeFB(frames[2 * N / 3], plate.W, plate.H, to: dir.appendingPathComponent("anim-f18.png"))
        print("Citadel: queen mock — wrote cutout + 3 stills + \(N)-frame anim GIF to \(dir.path)")
    }
}
