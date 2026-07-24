// Citadel — GPU SDF raymarcher: the shipping renderer's Metal compute kernel.
//
// The renderer pivot (2026-06-21): the world is rendered per-pixel on the GPU by
// sphere-tracing a signed-distance field instead of the CPU raycaster. The level
// stays a GRID, so the wall SDF is a Euclidean distance transform of the wall
// occupancy (precomputed CPU-side, sub-cell resolution, uploaded as a texture);
// the 3-D scene SDF is min(wallDistField(x,z), floorPlane, ceilingPlane). The
// Metal kernel marches that with per-pixel lighting + ambient occlusion, tinted
// by the baked colored-sector light field.
//
// This file is the HEADLESS PROOF/dev harness: it runs the SAME compute kernel
// that will drive the live renderer, but dispatches it offscreen, reads the
// texture back and writes a PNG — so the GPU path can be verified without a
// window (a live Metal drawable can't be screenshotted headlessly). Output:
// ~/Desktop/Citadel-GPU/. Stages 2-5 (PBR materials, dynamic lights+shadows,
// native SDF creatures, volumetrics/reflections/post) build on this kernel.

import Foundation
import Metal
import simd

enum GPURaymarch {
    static let sub = 8        // distance-field samples per cell (wall-face crispness)

    // ── Metal compute kernel (Stage 1: lit grid walls + AO + baked sector colour)
    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4 ro, fwd, right, up, params, grid, extra, env, vmA, vmB, dbg, tune; };  // extra.x = decalCount · env.xy = water-table offset (puddle field) · env.zw = viewmodel shape start/count · vmA = gun anchor.xyz + bound r · vmB = gun-local bound centre · dbg.x = disable creature mask · tune.x = overhead-lamp brightness gain
    struct GPULight { float4 posR; float4 colI; };   // posR=(x,y,z,1/r²)  colI=(r,g,b,intensity)
    struct GShape   { float4 a, b, col, bnd; };  // a.xyz,a.w=r1 ; b.xyz,b.w=r2(<0 → sphere) ; col.rgb,col.w=k ; bnd = enclosing sphere (CPU-filled)
    struct GMonster { float4 a, b, c; };    // a=(x,z,yaw,scale) b=(shapeStart,shapeCount,boundR,boundCY) c=(minY,…)
    // A burning source, integrated volumetrically along the view ray (fireEmission).
    // p0 = base.xyz + baseRadius(w) · p1 = flowDir.xyz(unit, up for a pyre / aim for
    // the jet) + length(w) · p2 = intensity(x) + seed(y) + kind(z: 0 pyre · 1 jet) + spare(w)
    struct FireEmitter { float4 p0, p1, p2; };
    // params = (screenW, viewH, horizon, ceilH);  grid = (mapW, mapH, monsterCount, lightCount)

    constant float3 WARM = float3(1.0, 0.92, 0.78);

    static inline float wallDist(texture2d<float> dt, sampler s, float2 xz, float2 mapWH) {
        return dt.sample(s, xz / mapWH).r;
    }
    // walls/floor/ceiling only — cheap, used by AO + dynamic-light shadows
    static inline float gridSDF(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH) {
        return min(wallDist(dt, s, p.xz, mapWH), min(p.y, ceilH - p.y));
    }
    // ── baked wall infrastructure: routed pipework ──
    // A pipe at perpendicular offset from the nearest wall, at height `ph`, is
    // just length(float2(dW - off, y - ph)) - r — dW being the perpendicular
    // distance to the wall means one expression runs the pipe along the wall
    // with NO per-instance cost. The baked routing mask `enable` (from map.pipe,
    // carried in the distance-field's .g channel) gates it, and each route end
    // is a RIGHT-ANGLED join: the run holds its offset, then a short elbow stub
    // turns 90° and goes straight into the wall — plumbing, not a taper. The
    // mask's bilinear ramp (0→1 over ~a cell) doubles as the along-the-wall
    // coordinate that places the elbow. Occasional fittings — a cutoff valve
    // (collar + stem + handwheel below) or a pressure gauge (stub + dial above)
    // — sit mid-run, keyed to position along the pipe. Folded into sceneSDF
    // (march + normals); fitting work early-outs unless the ray is on the pipe.
    static inline float pipeHash(float x) { return fract(sin(x * 127.1) * 43758.5453); }
    static inline float wallPipes(float3 p, float dW, float ceilH, float enable) {
        if (enable < 0.02) return 1e9;                       // unrouted: no pipe (buried; nothing to march)
        float ph = ceilH - 0.28;
        float dy = p.y - ph;
        // Terminations are plumbed like the real thing: the run holds its
        // offset, sweeps through a QUARTER-BEND (a torus arc) and enters the
        // wall square-on, with a bolted flange collar at the wall face and
        // another where the bend meets the straight — a flanged 90° main.
        // `u` ≈ distance along the wall from the terminus, reconstructed from
        // the routing mask's ramp (0.9× keeps it conservative for the march).
        // The elbow plane sits at 0.62, NOT the ramp's midpoint: a wall SHARED
        // with a piped room bleeds mask into the unpiped side's face, and that
        // bleed tops out at exactly 0.5 — at 0.55 the flange band clipped it
        // and extruded a phantom trough along the innocent room's wall.
        float u = (enable - 0.62) * 0.9;
        float2 q = float2(u - 0.10, dW);
        float d;
        if (q.x > 0.0) d = length(float2(dW - 0.10, dy)) - 0.038;             // the straight run
        else           d = length(float2(length(q) - 0.10, dy)) - 0.038;      // the quarter-bend into the wall
        float wallFlange = max(length(float2(u, dy)) - 0.062, dW - 0.028);    // bolted collar at the wall
        float runFlange  = max(length(float2(dW - 0.10, dy)) - 0.058, fabs(u - 0.115) - 0.015);
        d = min(d, min(wallFlange, runFlange));
        // (fittings — valves and gauges — are NOT derived here: they are
        //  CPU-placed objects with a true wall frame, see fittingDist below.
        //  Deriving them from x+z hashes sheared them on two of four wall
        //  orientations, sliced them on every routing-mask ramp, and put two
        //  on one run.)
        return d;
    }

    // ── pipe fittings ── CPU-placed (map.pipeFittings): each is (x, z, outward
    // normal angle, kind). The frame is TRUE — u along the wall, v off it,
    // h off the pipe axis — so the geometry can be real plant, modelled on the
    // reference stopcock: tapered bonnet on the run, rising stem, and a
    // red-enamel handwheel (rim + four spokes) with a bare-steel stem nut.
    // parts (out): x = red-enamel distance (rim/spokes/wheel hub) ·
    //              y = gauge-dial distance · zw = the dial's (u, h) for artwork.
    static inline float fittingDist(float3 p, float4 f, float ceilH, thread float3& parts, thread float2& dialUV) {
        float2 n2 = float2(cos(f.z), sin(f.z));
        float2 dxz = p.xz - f.xy;
        float v = dot(dxz, n2);                              // off the wall face
        float uu = dot(dxz, float2(-n2.y, n2.x));            // along the wall
        float h = p.y - (ceilH - 0.28);                      // off the pipe axis height
        float axisR = length(float2(uu, h));                 // radius off the stem axis
        parts = float3(1e9, 1e9, 0.0); dialUV = float2(0.0, 0.0);
        // Early-out with the distance TO the bounding volume (stem-axis cylinder
        // ∩ off-wall slab), never "infinity": a sphere tracer trusts this as a
        // step size, and an overstated far value lets a ray leap clean over the
        // wheel — visibility then hinged on where earlier steps happened to land,
        // so fittings flickered as the camera moved.
        float reach = f.w < 0.5 ? 0.10 : 0.17;               // handwheel vs gauge-dial radius
        float bound = max(axisR - reach, max(0.06 - v, v - 0.24));
        // Floor the bound above the march's hit epsilon (0.0015): without it,
        // rays CONVERGE onto the bounding surface itself and register phantom
        // hits — the fitting renders as a featureless dark puck. The floor is
        // safe: real geometry sits ≥ 0.02 inside the bound, so overstating the
        // shell by 4 mm can never step past anything.
        if (bound > 0.0) return max(bound, 0.004);
        if (f.w < 0.5) {                                     // ── SHUT-OFF VALVE ──
            float bonnet = max(axisR - (0.036 - 0.14 * (v - 0.10)), fabs(v - 0.124) - 0.028);
            float stem   = max(axisR - 0.011, fabs(v - 0.163) - 0.030);
            float rim    = length(float2(axisR - 0.052, v - 0.19)) - 0.0095;
            float spokes = max(length(float2(min(fabs(uu), fabs(h)), v - 0.19)) - 0.007, axisR - 0.052);
            float hub    = max(axisR - 0.014, fabs(v - 0.196) - 0.014);
            parts.x = min(rim, spokes);                      // the wheel wears the enamel
            return min(min(bonnet, stem), min(parts.x, hub));
        }
        // ── PRESSURE GAUGE ── a stub up off the run + a dial facing the room
        float stub = max(length(float2(uu, v - 0.10)) - 0.013, fabs(h - 0.045) - 0.045);
        float dial = max(length(float2(uu, h - 0.105)) - 0.038, fabs(v - 0.10) - 0.016);
        parts.y = dial; dialUV = float2(uu, h);
        return min(stub, dial);
    }
    static inline float fittingsField(float3 p, constant float4* fits, int n, float ceilH) {
        float best = 1e9;
        float3 parts; float2 uv;
        for (int i = 0; i < n; i++) {
            float2 dq = p.xz - fits[i].xy;
            float dd = dot(dq, dq);
            // Far fittings still contribute a bound (planar distance to the anchor
            // minus the fitting's reach — see fittingDist); skipping to "infinity"
            // here is what made the valves pop in and out with camera movement.
            if (dd > 0.36) { best = min(best, sqrt(dd) - 0.30); continue; }
            best = min(best, fittingDist(p, fits[i], ceilH, parts, uv));
        }
        return best;
    }

    // IQ round-cone (ported from CreatureLab) — the creature shape primitive
    static inline float sdRoundCone(float3 p, float3 a, float3 b, float r1, float r2) {
        float3 ba = b - a;
        float l2 = dot(ba, ba);
        if (l2 < 1e-7) return length(p - a) - r1;
        float rr = r1 - r2, a2 = l2 - rr * rr, il2 = 1.0 / l2;
        float3 pa = p - a;
        float y = dot(pa, ba), z = y - l2;
        float3 xp = pa * l2 - ba * y;
        float x2 = dot(xp, xp), y2 = y * y * l2, z2 = z * z * l2;
        float sgnR = (rr < 0.0) ? -1.0 : (rr > 0.0 ? 1.0 : 0.0);
        float k = sgnR * rr * rr * x2;
        float sgnZ = (z < 0.0) ? -1.0 : (z > 0.0 ? 1.0 : 0.0);
        if (sgnZ * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
        float sgnY = (y < 0.0) ? -1.0 : (y > 0.0 ? 1.0 : 0.0);
        if (sgnY * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
        return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
    }
    // nearest creature surface to p: rgb = flesh colour, w = world distance.
    // each monster is bounding-sphere culled, then its shapes smin-blended.
    // cmask: per-RAY bitmask of monsters whose bound sphere the ray can touch
    // (built once in the kernel). Every monster used to pay its local-space
    // transform + bound test per STEP per PIXEL — with a melee pack at the
    // camera that alone collapsed the frame rate. A masked-out monster is
    // > the mask margin from every point on the ray, so it can neither be
    // hit nor win a material contest: skipping it is exact.
    static inline float4 creatureField(float3 p, int nMon, constant GMonster* mons, constant GShape* shapes, ulong2 cmask, thread float& mat, thread float& emOut) {
        float best = 1e9; float3 bestCol = float3(0.5, 0.2, 0.18); mat = 0.0; float bestEm = 0.0; emOut = 0.0;
        for (int mi = 0; mi < nMon; mi++) {
            if (mi < 128 && (((mi < 64 ? cmask.x >> mi : cmask.y >> (mi - 64)) & 1) == 0)) continue;
            GMonster m = mons[mi];
            float scale = m.a.w;
            float2 d = p.xz - m.a.xy;
            float cs = m.a.z, sn = m.c.w;                        // cos/sin(-yaw), CPU-hoisted (fillMonsterTrig)
            float3 lp = float3((d.x * cs - d.y * sn) / scale, (p.y - m.c.y) / scale + m.c.x, (d.x * sn + d.y * cs) / scale);
            float bd = length(lp - float3(0.0, m.b.w, 0.0)) - m.b.z;   // bounding sphere (local)
            if (bd > 0.25) { best = min(best, bd * scale); continue; }
            int start = int(m.b.x), n = int(m.b.y);
            int G = (n + 7) / 8, sBase = start + G;               // [G group spheres][n shapes] — packShapeGroups layout
            float dd = 1e9; float3 col = float3(0.5, 0.2, 0.18); float em = 0.0;
            for (int gi = 0; gi < G; gi++) {
                // Group enclosing sphere: if the whole 8-shape run is provably
                // ≥ its max k beyond the running blend, every member is an
                // EXACT smin no-op (h = 1 leaves dd AND col untouched) — skip
                // the run wholesale. Compared squared to save the sqrt.
                GShape gb = shapes[start + gi];
                float grhs = dd + gb.col.w + gb.bnd.w;
                float3 gv = lp - gb.bnd.xyz;
                if (grhs <= 0.0 || dot(gv, gv) >= grhs * grhs) continue;
                int s1 = min(gi * 8 + 8, n);
                for (int si = gi * 8; si < s1; si++) {
                    GShape sh = shapes[sBase + si];
                    float k = sh.col.w;
                    float rhs = dd + k + sh.bnd.w;                // per-shape: the same exact no-op test
                    float3 v = lp - sh.bnd.xyz;
                    if (rhs <= 0.0 || dot(v, v) >= rhs * rhs) continue;
                    float sd;
                    if (sh.b.w < -2.5) {                          // flat-capped cylinder (drums) — FLAT top + bottom
                        float3 q = lp - sh.a.xyz;
                        float2 dcy = float2(length(q.xz) - (sh.a.w - sh.b.x), abs(q.y) - (sh.b.y - sh.b.x));
                        sd = min(max(dcy.x, dcy.y), 0.0) + length(max(dcy, 0.0)) - sh.b.x;
                    } else if (sh.b.w < -1.5) {                   // rounded box (items)
                        float3 q = abs(lp - sh.a.xyz) - sh.b.xyz;
                        sd = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - sh.a.w;
                    } else if (sh.b.w < 0.0) {                    // sphere
                        sd = length(lp - sh.a.xyz) - sh.a.w;
                    } else {                                      // round cone
                        sd = sdRoundCone(lp, sh.a.xyz, sh.b.xyz, sh.a.w, sh.b.w);
                    }
                    float shEm = (sh.b.w < 0.0 && sh.b.w > -1.5) ? sh.b.x : 0.0;   // sphere-only emissive (ova / eyes)
                    if (dd > 1e8) { dd = sd; col = sh.col.rgb; em = shEm; }
                    else {
                        float h = clamp(0.5 + 0.5 * (sd - dd) / k, 0.0, 1.0);
                        dd = mix(sd, dd, h) - k * h * (1.0 - h);
                        col = mix(sh.col.rgb, col, h);
                        em = mix(shEm, em, h);
                    }
                }
            }
            dd *= scale;
            if (dd < best) { best = dd; bestCol = col; mat = m.c.z; bestEm = em; }   // c.z = material (1 = pickup)
        }
        emOut = bestEm;
        return float4(bestCol, best);
    }
    // March/normal variant: distance ONLY. Identical smin arithmetic (rays must
    // see the exact field the shading pass sees) minus the colour blends, plus
    // the same exact enclosing-sphere skip — this loop runs per STEP per PIXEL
    // and dominates the frame when a creature fills the screen.
    static inline float4 creatureField(float3 p, int nMon, constant GMonster* mons, constant GShape* shapes, ulong2 cmask) {
        float best = 1e9;
        for (int mi = 0; mi < nMon; mi++) {
            if (mi < 128 && (((mi < 64 ? cmask.x >> mi : cmask.y >> (mi - 64)) & 1) == 0)) continue;
            GMonster m = mons[mi];
            float scale = m.a.w;
            float2 d = p.xz - m.a.xy;
            float cs = m.a.z, sn = m.c.w;                        // cos/sin(-yaw), CPU-hoisted (fillMonsterTrig)
            float3 lp = float3((d.x * cs - d.y * sn) / scale, (p.y - m.c.y) / scale + m.c.x, (d.x * sn + d.y * cs) / scale);
            float bd = length(lp - float3(0.0, m.b.w, 0.0)) - m.b.z;   // bounding sphere (local)
            if (bd > 0.25) { best = min(best, bd * scale); continue; }
            int start = int(m.b.x), n = int(m.b.y);
            int G = (n + 7) / 8, sBase = start + G;               // [G group spheres][n shapes] — packShapeGroups layout
            float dd = 1e9;
            for (int gi = 0; gi < G; gi++) {
                GShape gb = shapes[start + gi];
                float grhs = dd + gb.col.w + gb.bnd.w;            // whole run is an exact smin no-op
                float3 gv = lp - gb.bnd.xyz;
                if (grhs <= 0.0 || dot(gv, gv) >= grhs * grhs) continue;
                int s1 = min(gi * 8 + 8, n);
                for (int si = gi * 8; si < s1; si++) {
                    GShape sh = shapes[sBase + si];
                    float k = sh.col.w;
                    float rhs = dd + k + sh.bnd.w;                // exact smin no-op, compared squared
                    float3 v = lp - sh.bnd.xyz;
                    if (rhs <= 0.0 || dot(v, v) >= rhs * rhs) continue;
                    float sd;
                    if (sh.b.w < -2.5) {
                        float3 q = lp - sh.a.xyz;
                        float2 dcy = float2(length(q.xz) - (sh.a.w - sh.b.x), abs(q.y) - (sh.b.y - sh.b.x));
                        sd = min(max(dcy.x, dcy.y), 0.0) + length(max(dcy, 0.0)) - sh.b.x;
                    } else if (sh.b.w < -1.5) {
                        float3 q = abs(lp - sh.a.xyz) - sh.b.xyz;
                        sd = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - sh.a.w;
                    } else if (sh.b.w < 0.0) {
                        sd = length(lp - sh.a.xyz) - sh.a.w;
                    } else {
                        sd = sdRoundCone(lp, sh.a.xyz, sh.b.xyz, sh.a.w, sh.b.w);
                    }
                    if (dd > 1e8) { dd = sd; }
                    else {
                        float h = clamp(0.5 + 0.5 * (sd - dd) / k, 0.0, 1.0);
                        dd = mix(sd, dd, h) - k * h * (1.0 - h);
                    }
                }
            }
            best = min(best, dd * scale);
        }
        return float4(0.0, 0.0, 0.0, best);
    }
    // ── the marine's weapon (viewmodel) ── a private field marched as an
    // OVERLAY after the world resolves: it is deliberately NOT in sceneSDF, so
    // world geometry can never swallow the held weapon (the classic FPS
    // cleared-depth trick). Marched in GUN-LOCAL space (x right · y up ·
    // z forward) so its boxes/cylinders stay gun-aligned at any view angle.
    // Two vm-only shape encodings join the shared set:
    //   b.w = -4 → z-axis flat-cap cylinder (a.w = R, b.x = edge round, b.y = half-length, b.z = emissive)
    //   b.w = -5 → emissive sphere (a.w = r, b.x = emissive)
    // and b.z carries emissive on the y-cylinder (-3) too.
    static inline float vmShapeDist(GShape sh, float3 p, thread float& em) {
        em = 0.0;
        if (sh.b.w < -4.5) { em = sh.b.x; return length(p - sh.a.xyz) - sh.a.w; }
        if (sh.b.w < -3.5) {                              // z-axis flat-cap cylinder
            em = sh.b.z;
            float3 q = p - sh.a.xyz;
            float2 dcy = float2(length(q.xy) - (sh.a.w - sh.b.x), fabs(q.z) - (sh.b.y - sh.b.x));
            return min(max(dcy.x, dcy.y), 0.0) + length(max(dcy, 0.0)) - sh.b.x;
        }
        if (sh.b.w < -2.5) {                              // y-axis flat-cap cylinder
            em = sh.b.z;
            float3 q = p - sh.a.xyz;
            float2 dcy = float2(length(q.xz) - (sh.a.w - sh.b.x), fabs(q.y) - (sh.b.y - sh.b.x));
            return min(max(dcy.x, dcy.y), 0.0) + length(max(dcy, 0.0)) - sh.b.x;
        }
        if (sh.b.w < -1.5) {                              // rounded box
            float3 q = fabs(p - sh.a.xyz) - sh.b.xyz;
            return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - sh.a.w;
        }
        if (sh.b.w < 0.0) return length(p - sh.a.xyz) - sh.a.w;   // sphere
        return sdRoundCone(p, sh.a.xyz, sh.b.xyz, sh.a.w, sh.b.w);
    }
    static inline float4 vmField(float3 p, constant GShape* shapes, int start, int count, thread float& emis) {
        float dd = 1e9; float3 col = float3(0.3, 0.3, 0.3); float em = 0.0;
        for (int si = start; si < start + count; si++) {
            GShape sh = shapes[si];
            float e; float sd = vmShapeDist(sh, p, e);
            float k = sh.col.w;
            if (dd > 1e8) { dd = sd; col = sh.col.rgb; em = e; }
            else {
                float h = clamp(0.5 + 0.5 * (sd - dd) / k, 0.0, 1.0);
                dd = mix(sd, dd, h) - k * h * (1.0 - h);
                col = mix(sh.col.rgb, col, h);
                em = mix(e, em, h);
            }
        }
        emis = em;
        return float4(col, dd);
    }
    // full field: grid + creatures + pipe fittings — the primary march + normals
    static inline float sceneSDF(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH,
                                 int nMon, constant GMonster* mons, constant GShape* shapes,
                                 constant float4* fits, int nFits, ulong2 cmask) {
        float2 dd = dt.sample(s, p.xz / mapWH).rg;           // .r wall distance · .g pipe-routing enable
        float dW = dd.x;
        float g = min(dW, min(p.y, ceilH - p.y));
        g = min(g, wallPipes(p, dW, ceilH, dd.y));           // baked routed pipework (marched + normals; not AO/shadow)
        if (nFits > 0) g = min(g, fittingsField(p, fits, nFits, ceilH));
        if (nMon > 0 && (cmask.x | cmask.y) != 0) g = min(g, creatureField(p, nMon, mons, shapes, cmask).w);
        return g;
    }
    static inline float3 calcNormal(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH,
                                    int nMon, constant GMonster* mons, constant GShape* shapes,
                                    constant float4* fits, int nFits, ulong2 cmask) {
        float2 e = float2(0.004, 0.0);
        float dx = sceneSDF(p + e.xyy, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask) - sceneSDF(p - e.xyy, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask);
        float dy = sceneSDF(p + e.yxy, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask) - sceneSDF(p - e.yxy, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask);
        float dz = sceneSDF(p + e.yyx, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask) - sceneSDF(p - e.yyx, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask);
        return normalize(float3(dx, dy, dz));
    }
    static inline float calcAO(float3 p, float3 n, texture2d<float> dt, sampler s, float2 mapWH, float ceilH) {
        float occ = 0.0, sca = 1.0;
        for (int i = 0; i < 5; i++) {
            float h = 0.015 + 0.08 * float(i);
            occ += (h - gridSDF(p + n * h, dt, s, mapWH, ceilH)) * sca;
            sca *= 0.9;
        }
        return clamp(1.0 - 1.6 * occ, 0.0, 1.0);
    }
    static inline float softShadow(float3 ro, float3 rd, float maxt, float k,
                                   texture2d<float> dt, sampler s, float2 mapWH, float ceilH) {
        float res = 1.0, t = 0.03;
        for (int i = 0; i < 40; i++) {
            if (t >= maxt) break;
            float h = gridSDF(ro + rd * t, dt, s, mapWH, ceilH);
            if (h < 0.001) return 0.0;
            res = min(res, k * h / t);
            t += clamp(h, 0.02, 0.5);
        }
        return clamp(res, 0.0, 1.0);
    }
    // Cheap HARD occlusion for the colour FILL lights: march the horizontal wall
    // field toward the light and block on the first wall or CLOSED DOOR between the
    // surface and the light. Ignores floor/ceiling (the leak is through walls/doors,
    // and skipping y avoids grazing self-shadow), early-outs on a hit, and — unlike a
    // full soft shadow — is cheap enough to run on every fill. In-room fills with a
    // clear path march to the light and stay lit, so the "fills spill freely" look is
    // untouched; only cross-wall / cross-closed-door bleed is cut.
    static inline float wallBlocked(float3 ro, float3 rd, float maxt,
                                    texture2d<float> dt, sampler s, float2 mapWH) {
        float t = 0.08;
        for (int i = 0; i < 20; i++) {
            if (t >= maxt) break;
            float h = wallDist(dt, s, (ro + rd * t).xz, mapWH);
            if (h < 0.03) return 0.0;               // a wall or a closed door blocks the light
            t += max(h, 0.06);
        }
        return 1.0;
    }

    static inline float wallEmissive(uint id) {
        if (id == 4u)  return 0.85;
        if (id == 16u) return 1.05;
        if (id == 10u) return 0.60;
        if (id == 13u || id == 14u || id == 15u || id == 17u) return 0.45;
        if (id == 18u) return 0.5;
        return 0.0;
    }
    static inline float flatEmissive(uint id) { return id == 3u ? 0.85 : 0.0; }

    // ── ceiling lamp grid: recessed warm housings on a world-cell grid, only
    //    hung over open cells, with per-fixture flicker / failure / dead bulbs ──
    constant float LAMP_HALF  = 0.34;          // half-width of the recessed lit face (cell-relative)
    constant float3 LAMP_WARM = float3(1.0, 0.82, 0.55);

    static inline float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    static inline float hash11(float x)  { return fract(sin(x * 12.9898) * 43758.5453); }
    // per-fixture output 0..1, stable per cell: ~8% dead, ~16% erratically failing
    // (random stepped dropouts — NOT a regular rhythm), the rest a near-steady hum.
    static inline float fixtureFlicker(float2 cell, float time) {
        float h = hash21(cell);
        if (h < 0.08) return 0.0;                                   // dead bulb
        if (h < 0.24) {                                            // failing — erratic, random blackouts
            float t = time * (6.0 + 7.0 * h);                      // per-fixture rate
            float a = hash11(floor(t) + h * 53.0);                 // random step
            float b = hash11(floor(t * 2.31 + 4.0) + h * 91.0);    // faster, incommensurate → no rhythm
            float v = min(a, b);
            return v < 0.4 ? 0.05 : v;
        }
        return 0.9 + 0.06 * sin(time * 2.0 + h * 24.0);            // healthy: barely-there hum
    }
    // a lamp hangs in every other open cell in both axes (one per 2×2 block),
    // so the fixtures follow the actual corridor layout rather than a blind grid.
    static inline bool isLampCell(int2 c) { return ((c.x & 1) == 0) && ((c.y & 1) == 0); }
    static inline float2 nearestLampCenter(float2 xz) { return float2(round((xz - 0.5) * 0.5) * 2.0) + 0.5; }

    // ── battle damage ── integer hash (all uint, so the CPU side matches EXACTLY
    //   and sparks emit from the same panels that render shattered) + value noise
    static inline uint ihash(int x, int y) {
        uint h = uint(x) * 374761393u + uint(y) * 668265263u;
        h = (h ^ (h >> 13)) * 1274126177u;
        return h ^ (h >> 16);
    }
    static inline bool fixtureBusted(int2 c) { return (ihash(c.x, c.y) % 100u) < 32u; }   // ~⅓ shattered
    static inline float vnoise2(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    static inline float fbm2(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) { s += a * vnoise2(p); p *= 2.03; a *= 0.5; }
        return s;
    }
    // ── 3-D value noise for the volumetric FIRE puffs (fireEmission) ──
    // Sin-free Dave-Hoskins hash — cheaper than the file's sin-hash, which matters
    // at a few taps per puff.
    static inline float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }
    static inline float vnoise3(float3 p) {
        float3 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash13(i + float3(0,0,0)), b = hash13(i + float3(1,0,0));
        float c = hash13(i + float3(0,1,0)), d = hash13(i + float3(1,1,0));
        float e = hash13(i + float3(0,0,1)), g = hash13(i + float3(1,0,1));
        float h = hash13(i + float3(0,1,1)), k = hash13(i + float3(1,1,1));
        return mix(mix(mix(a,b,f.x), mix(c,d,f.x), f.y),
                   mix(mix(e,g,f.x), mix(h,k,f.x), f.y), f.z);
    }
    static inline float fbm3(float3 p) {                 // 3 octaves ≈ 0 … 0.87
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 3; i++) { s += a * vnoise3(p); p *= 2.02; a *= 0.5; }
        return s;
    }
    // temperature → emissive HDR colour. Reference power ramp (red~2n, green~n³,
    // blue~n⁵): white-hot core → yellow → orange → deep red → BLACK. Cores exceed
    // 1.0 so they clear the post bright-pass and bloom white.
    static inline float3 blackbodyFire(float T) {
        T = clamp(T, 0.0, 1.0);
        return float3(1.90 * T, 1.15 * T * T * T, 0.35 * T * T * T * T * T);
    }

    // ── standing water (the deep rock floors) ── floor 7 doesn't flood, it POOLS.
    //   Value noise on the INTEGER hash so the CPU samples the identical field
    //   (Lighting.puddle — kept in lockstep, the same trick as fixtureBusted):
    //   the puddles the kernel draws are exactly the puddles the game splashes
    //   and drips in. Callers add the level's water-table offset (U.env.xy).
    static inline float ihash01(int x, int y) { return float(ihash(x, y) & 0xFFFFu) / 65535.0; }
    static inline float inoise2(float2 q) {
        float2 i = floor(q), f = fract(q);
        f = f * f * (3.0 - 2.0 * f);
        int2 c = int2(i);
        float a = ihash01(c.x, c.y), b = ihash01(c.x + 1, c.y);
        float cc = ihash01(c.x, c.y + 1), d = ihash01(c.x + 1, c.y + 1);
        return mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
    }
    // a broad octave shapes the pools, a finer one frays their edges
    static inline float puddleField(float2 xz) { return 0.65 * inoise2(xz * 0.55) + 0.35 * inoise2(xz * 1.9 + 31.0); }
    static inline float puddleMask(float f) { return smoothstep(0.50, 0.60, f); }

    // ── PBR material params + micro-relief (the "walls & materials" model) ──────
    // Per-surface roughness/metalness, mirroring BeautyProof's material(): grimy
    // iron is a dirty half-metal, brushed steel / pipes are cleaner metal, glass
    // is a smooth dielectric, stone & concrete are matte. (x = rough, y = metal.)
    // Bases lean DULL: this is a working colony, not a showroom — decades of
    // hands, boots and grit have taken the factory sheen off every panel (low
    // roughness on broad flats read as wet plastic). Glass, screens and the
    // creatures keep their gloss; per-pixel WEAR (at the shading sites) then
    // breaks what sheen remains into patchy smudges.
    static inline float2 wallMaterial(uint id) {
        switch (id) {
            case 2u:  return float2(0.48, 0.70);   // brushed steel — the good rooms
            case 5u:  return float2(0.46, 0.65);   // ribbed conduit metal
            case 6u:  return float2(0.28, 0.80);   // pipework — smooth metal
            case 7u:  return float2(0.18, 0.25);   // reinforced glass — smooth dielectric
            case 8u:  return float2(0.92, 0.00);   // hewn rock — matte
            case 9u:  return float2(0.70, 0.35);   // rock + steel struts
            case 10u: return float2(0.50, 0.20);   // computer banks — screens
            case 12u: case 13u: case 14u: case 15u: case 17u: case 18u: return float2(0.58, 0.50);  // blast doors — painted steel
            case 16u: return float2(0.58, 0.45);   // exit switch panel
            case 19u: return float2(0.50, 0.60);   // lift-car lining — machined steel box
            default:  return float2(0.68, 0.50);   // iron plate / steel panel / lit panel / hazard — grimy iron
        }
    }
    // floor + ceiling flats: metal deck / grate are metal, concrete / stone matte.
    static inline float2 flatMaterial(uint id) {
        switch (id) {
            case 1u: return float2(0.56, 0.65);    // metal deck plate
            case 2u: return float2(0.63, 0.55);    // walkway grate
            case 4u: return float2(0.62, 0.25);    // ceiling tech
            case 5u: return float2(0.82, 0.08);    // dark ceiling
            case 6u: case 7u: return float2(0.92, 0.00);   // stone / rock — matte
            default: return float2(0.82, 0.05);    // concrete — matte
        }
    }
    // perturb the normal along the gradient of surface noise → grain/rivets that
    // actually catch the light (BeautyProof.bumped, in-kernel). tU/tV span the
    // surface; smoother materials bump less (polished = flatter).
    static inline float3 bumpNormal(float2 uv, float3 n, float3 tU, float3 tV, float scale, float amt) {
        float e = 0.06;
        float gx = fbm2((uv + float2(e, 0.0)) * scale) - fbm2((uv - float2(e, 0.0)) * scale);
        float gy = fbm2((uv + float2(0.0, e)) * scale) - fbm2((uv - float2(0.0, e)) * scale);
        float2 g = float2(gx, gy) / (2.0 * e);
        return normalize(n - amt * (tU * g.x + tV * g.y));
    }
    // ── structural wall relief ── a height field over (along-wall, up): bulkhead
    // panels divided by recessed seams, plus raised vertical I-beam ribs at wider
    // intervals. Shaded only (albedo + normal), so it gives the flat walls real
    // depth + steelwork at zero march cost. uv in world units (1 = a cell).
    static inline float wallRelief(float2 uv) {
        // Groove frequency 2.0/unit on BOTH axes: the baked wall textures panel
        // at 128px = half a 256px tile = half a world cell, so the shaded seams
        // land exactly on the textures' own panel seams and on cell boundaries.
        // (They were 1.7/2.5 — a second, unrelated seam grid sliced across the
        // baked one and the walls read as a mess.)
        float gv = smoothstep(0.04, 0.12, abs(fract(uv.x * 2.0) - 0.5));        // vertical seam grooves
        float gh = smoothstep(0.04, 0.12, abs(fract(uv.y * 2.0) - 0.5));        // horizontal seam grooves
        float panel = min(gv, gh);                                             // recessed where the seams cross
        float rib = 1.0 - smoothstep(0.40, 0.50, abs(fract(uv.x * 0.5) - 0.5));  // a raised steel rib every 2 cells (on cell boundaries)
        return panel * 0.7 + rib * 0.5;
    }
    // Fresnel-weighted Blinn-Phong specular lobe (BeautyProof's spec term).
    static inline float3 specBP(float3 n, float3 V, float3 Ld, float rough, float3 f0) {
        float3 H = normalize(Ld + V);
        float ndh = max(0.0, dot(n, H));
        float hdv = max(0.0, dot(H, V));
        float specPow = mix(8.0, 340.0, pow(1.0 - rough, 1.4));
        float3 fres = f0 + (float3(1.0) - f0) * pow(1.0 - hdv, 5.0);
        return fres * (pow(ndh, specPow) * (specPow + 8.0) / 25.0);
    }

    // cheap one-bounce environment shade for wet-floor reflections (grid only,
    // no AO/shadow/creatures) — the lit corridor + glowing panels mirrored back.
    static inline float3 reflectShade(float3 ro, float3 rd, texture2d<float> dt, sampler s, sampler ts,
                                      float2 mapWH, float ceilH, texture2d<float> lightTex,
                                      texture2d_array<float> wallArr, texture2d_array<float> flatArr,
                                      texture2d<ushort, access::read> wallId,
                                      texture2d<ushort, access::read> floorId,
                                      texture2d<ushort, access::read> ceilId) {
        float t = 0.03; bool hit = false;
        for (int i = 0; i < 70; i++) {
            float h = gridSDF(ro + rd * t, dt, s, mapWH, ceilH);
            if (h < 0.002) { hit = true; break; }
            t += h * 0.9;
            if (t > 40.0) break;
        }
        if (!hit) return float3(0.01, 0.012, 0.02);
        float3 p = ro + rd * t;
        float dW = wallDist(dt, s, p.xz, mapWH), dF = p.y, dC = ceilH - p.y;
        int2 dim = int2(mapWH);
        float3 alb; float emis = 0.0;
        if (dW <= dF && dW <= dC) {
            int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
            uint id = wallId.read(uint2(c)).r;
            alb = wallArr.sample(ts, float2(p.x + p.z, 1.0 - p.y), id).rgb; emis = wallEmissive(id);
        } else if (dF <= dC) {
            int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
            uint id = floorId.read(uint2(c)).r;
            alb = flatArr.sample(ts, p.xz, id).rgb; emis = flatEmissive(id);
        } else {
            int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
            uint id = ceilId.read(uint2(c)).r;
            alb = flatArr.sample(ts, p.xz, id).rgb;
            // the wet floor must mirror the bright lamps — thinned on stone
            // ceilings exactly as the main ceiling pass thins them
            if (isLampCell(c) && (id != 6u || (ihash(c.x, c.y) % 3u) == 0u)) {
                float2 ctr = float2(c) + 0.5;
                float mm = max(abs(p.x - ctr.x), abs(p.z - ctr.y));
                if (mm < LAMP_HALF) {
                    float face = 1.0 - smoothstep(LAMP_HALF * 0.42, LAMP_HALF, mm);
                    alb = mix(float3(0.06, 0.06, 0.08), LAMP_WARM, face);
                    emis = 7.5 * face;
                }
            }
        }
        float3 sect = lightTex.sample(s, p.xz / mapWH).rgb;
        return (alb * (sect * 0.9 + emis)) * exp(-t * 0.05);
    }

    // volumetric in-scatter along the view ray: base haze + low-lying steam,
    // tinted by the baked sector glow, plus dynamic-light glow (muzzle/shots).
    static inline float3 volumetric(float3 ro, float3 rd, float tmax, texture2d<float> dt, sampler s,
                                    float2 mapWH, texture2d<float> lightTex, int nL,
                                    constant GPULight* lights, float jit) {
        int steps = 22;
        float far = min(tmax, 28.0), ds = far / float(steps);
        float t = ds * (0.3 + 0.7 * jit);
        float3 acc = float3(0.0); float trans = 1.0;
        for (int i = 0; i < steps; i++) {
            float3 p = ro + rd * t;
            float dens = 0.003 + 0.010 * clamp(1.4 - p.y, 0.0, 1.0);   // base + steam near the floor (trimmed — many lights now)
            float3 sg = lightTex.sample(s, p.xz / mapWH).rgb;       // ambient haze — desaturated so big rooms
            float3 g = mix(float3(dot(sg, float3(0.30, 0.59, 0.11))), sg, 0.5) * 0.20;   // don't fog one solid hue
            for (int li = 0; li < nL; li++) {
                float3 tl = lights[li].posR.xyz - p;
                float f = 1.0 - dot(tl, tl) * lights[li].posR.w;
                if (f > 0.0) g += lights[li].colI.rgb * (lights[li].colI.w * f * f * 0.30);   // many emitters now → don't fog
            }
            acc += g * (dens * ds * trans);
            trans *= exp(-dens * ds);
            t += ds;
            if (trans < 0.03) break;
        }
        return acc * 0.7;
    }

    // ── volumetric fire ── each emitter is a rising, tapering tongue of flame
    // integrated along the view ray: bounded to its enclosing sphere (so a ray
    // that misses it pays ~10 flops), then a short mini-march accumulates
    // additive HDR emission from a domain-warped FBM turbulence field that
    // scrolls UP with time (buoyancy). White-hot at the base → orange → deep red
    // at the flickering tip. Occluded by `tmax` (the nearest opaque surface), so
    // walls cut the jet and the world sits in front of a distant pyre. Cost is
    // proportional to fire's SCREEN coverage, never full-frame — and it lives on
    // the GPU, not the CPU blend loop that used to spin the fans.
    // Fire = a recycling CHAIN of analytic 3-D PUFFS per emitter (real fire is many
    // small rolling/mushrooming puffs), NOT a volumetric FBM ray-march. Each puff is
    // ONE ray-vs-sphere (chord thickness → opaque core + soft rim for free), carved by
    // ONE fixed-WORLD-FREQUENCY 3-D turbulence sample (crisp — no along-ray averaging),
    // composited FRONT-TO-BACK. This structurally kills: the soft-cloud average, the
    // summed white dome down the jet (a convex opacity blend can't blow out), and any
    // straight line/cylinder (a jittered union of carved blobs has no axis). Colour is
    // TEMPERATURE (blackbodyFire: white→yellow→orange→red→black), never height; old
    // puffs flip to absorbing warm-black SMOKE that darkens the fire-lit walls behind
    // it — that value contrast is what reads as fire, not glow. `bgTransOut` = how much
    // scene survives the smoke, applied by the caller (col = col*bg + acc).
    static inline float3 fireEmission(float3 ro, float3 rd, float tmax, float ceilH,
                                      constant FireEmitter* F, int n, float time,
                                      thread float& bgTransOut) {
        float3 acc = float3(0.0);
        float bgTrans = 1.0;                                        // scene survival behind ALL fire
        for (int i = 0; i < n; i++) {
            float3 base = F[i].p0.xyz;  float baseR    = F[i].p0.w;
            float3 flow = F[i].p1.xyz;  float len      = F[i].p1.w;
            float vigor = F[i].p2.x;    float seed     = F[i].p2.y;
            bool  jet   = F[i].p2.z > 0.5;  float smokeBias = F[i].p2.w;   // Queen = sootier
            // whole-plume bounding-sphere reject (~12 flops on a miss)
            float3 bc = base + flow * (len * 0.5);
            float  bR = len * 0.6 + baseR * 2.4 + 0.35;
            float3 oc = ro - bc; float bq = dot(oc, rd);
            if (bq * bq - (dot(oc, oc) - bR * bR) <= 0.0) continue;
            // basis ⟂ to the flow, for lateral puff wander (pyre flow=up → e1=(1,0,0))
            float3 up = fabs(flow.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
            float3 e1 = normalize(cross(flow, up));
            float3 e2 = cross(flow, e1);
            float fk    = 0.80 + 0.14 * sin(time * 11.0 + seed * 6.3)
                               + 0.10 * sin(time * 27.0 + seed * 15.1);   // arrhythmic gutter
            float opac  = clamp(vigor * 0.60, 0.38, 1.0);
            float bright= clamp(vigor * 0.85, 0.30, 1.6) * fk;
            int   NP    = jet ? 8 : 10;
            float rate  = jet ? 2.2 : 0.9;                 // jet churns fast; pyre rolls slow
            float drift = fract(time * rate);              // whole chain slides + recycles
            float scr   = jet ? 3.2 : 1.7;                 // internal turbulence scroll speed
            float trans = 1.0;                             // this emitter, front-to-back
            float3 localAcc = float3(0.0);
            for (int k = 0; k < NP; k++) {
                // axial age 0(source)…1(tip); monotonic in k ⇒ k-order == depth order,
                // source first (nozzle nearest head-on; flame-below-smoke for a pyre)
                float age  = (float(k) + drift) / float(NP);
                float fade = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.86, 1.0, age));
                if (fade < 0.02) continue;
                // puff centre rides the flow and WANDERS (grows with age → mushrooms).
                // Cheap sines, NO noise eval → placement costs ~nothing per pixel.
                float ph  = seed * 6.3 + float(k) * 1.7;
                float wob = baseR * (jet ? 0.35 : 0.85) * (0.35 + 1.9 * age);
                float wa  = sin(age * 5.1 + ph)       + 0.5 * sin(age * 11.7 + ph * 1.7);
                float wb  = cos(age * 4.3 + ph * 1.3) + 0.5 * sin(age *  9.3 + ph * 0.7);
                float3 C  = base + flow * (age * len) + (e1 * wa + e2 * wb) * (wob * 0.5);
                if (!jet) C.y = min(C.y, ceilH - 0.05);    // smoke flattens & rolls at the ceiling
                // radius: tiny hot nucleus at the source, ballooning as it cools
                float R = jet ? baseR * (0.16 + 1.05 * age)
                              : baseR * (0.45 + 0.75 * age);
                // ── analytic ray-vs-sphere → chord thickness (opaque core, soft rim) ──
                float3 rel = ro - C;
                float b2 = dot(rel, rd);
                float c2 = dot(rel, rel) - R * R;
                float disc = b2 * b2 - c2;
                if (disc <= 0.0) continue;                 // MISS → no noise paid (cheap reject)
                float sq = sqrt(disc);
                float t0 = max(0.0, -b2 - sq);
                float t1 = min(tmax, -b2 + sq);            // clipped by nearest opaque surface (volT)
                if (t1 <= t0) continue;                    // behind a wall / behind the eye
                float thick = (t1 - t0) / (2.0 * R);       // 0 rim … 1 through the centre
                // ── carve organic shape from FIXED-WORLD-FREQUENCY 3-D turbulence ──
                // sampled at the front surface: same absolute detail on tiny & huge puffs
                // (no smooth disc), scrolling back along the flow so structure blows out.
                float3 sp   = (ro + rd * t0) * 7.0 - flow * (time * scr) + seed * 11.0;
                float  turb = fbm3(sp);                    // ONE crisp sample — no averaging
                // ragged silhouette + interior voids: low turb eats chunks out of the rim
                float dens = smoothstep(0.05, 0.42, thick - (0.72 - turb) * 0.60) * fade;
                if (dens < 0.004) continue;
                // ── temperature: cooling ramp. Pyre peaks ABOVE the base so the white-hot
                // core clears the rasterised corpse mesh; jet is white-hot at the nozzle. ──
                float axial = jet ? (1.0 - 0.65 * age)
                                  : (smoothstep(0.0, 0.16, age) * (1.0 - 0.75 * age));
                float heat  = clamp(axial * (0.35 + 0.85 * turb) * (0.50 + 0.65 * thick), 0.0, 1.0);
                float smokeF= smoothstep(0.42 - 0.14 * smokeBias, 0.88, age);   // old → soot
                float flameA= dens * opac * (1.0 - smokeF);        // OPAQUE hot core
                float smokeA= dens * (0.55 + 0.40 * smokeBias) * smokeF;        // ABSORBS the bg
                float3 emis     = blackbodyFire(heat) * bright;
                float3 smokeCol = mix(float3(0.05, 0.035, 0.028),  // warm soot near the flame …
                                      float3(0.012, 0.012, 0.013), // … cold black up high
                                      smokeF);
                // front-to-back: flame emits + occludes; smoke faintly self-lit + absorbs
                localAcc += emis * (flameA * trans) + smokeCol * (smokeA * trans);
                trans    *= (1.0 - flameA) * (1.0 - smokeA);
                if (trans < 0.02) break;                   // pixel is opaque → stop
            }
            acc += localAcc * bgTrans;                     // near emitters (sent first) occlude far
            bgTrans *= trans;
        }
        bgTransOut = bgTrans;
        return acc * 2.0;                                  // HDR gain → white cores bloom in post
    }

    kernel void raymarch(uint2 gid [[thread_position_in_grid]],
                         texture2d<float> dt        [[texture(0)]],
                         texture2d<float> lightTex  [[texture(1)]],
                         texture2d<float, access::write> outTex [[texture(2)]],
                         texture2d_array<float> wallArr [[texture(3)]],
                         texture2d_array<float> flatArr [[texture(4)]],
                         texture2d<ushort, access::read> wallId  [[texture(5)]],
                         texture2d<ushort, access::read> floorId [[texture(6)]],
                         texture2d<ushort, access::read> ceilId  [[texture(7)]],
                         texture2d<float, access::write> depthTex [[texture(8)]],
                         constant GPULight* lights [[buffer(1)]],
                         constant GMonster* mons   [[buffer(2)]],
                         constant GShape* shapes   [[buffer(3)]],
                         constant float4* decals   [[buffer(4)]],   // (x,z,radius,w): w>0 scorch · w<0 blood
                         constant float4* doorsB   [[buffer(5)]],   // (cellX, cellY, part 0…1, flags: bit0 slideX · bit1 elevator)
                         constant float4* fits     [[buffer(6)]],   // pipe fittings: (x, z, normal angle, kind) — count in U.vmB.w
                         constant FireEmitter* fires [[buffer(7)]],  // burning sources — count in U.tune.y (0 ⇒ never read)
                         constant Uniforms& U [[buffer(0)]]) {
        float screenW = U.params.x, viewH = U.params.y, horizon = U.params.z, ceilH = U.params.w;
        if (gid.x >= uint(screenW) || gid.y >= uint(viewH)) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        constexpr sampler ts(filter::linear, address::repeat, coord::normalized);
        float2 mapWH = U.grid.xy;
        int nMon = int(U.grid.z);

        float cameraX = 2.0 * (float(gid.x) + 0.5) / screenW - 1.0;
        // vertical slope is pinned to the 2:1-calibrated row count (width/2), so a
        // taller viewport widens the vertical FOV instead of stretching the world
        float vcomp = (horizon - (float(gid.y) + 0.5)) / (0.5 * screenW);
        float3 rd = normalize(U.fwd.xyz + U.right.xyz * cameraX + U.up.xyz * vcomp);
        float3 ro = U.ro.xyz;
        float time = U.ro.w;

        int nFits = int(U.vmB.w);
        // Per-ray creature culling, computed ONCE: which monster bounds can this
        // ray touch (bitmask), and over what t-range (window). Outside the window
        // the creature field is skipped wholesale — so when a biter fills the
        // screen, rays pointing at the floor stop paying for it after a step or
        // two instead of on all ~190.
        ulong2 cmask = ulong2(0);                            // 128-instance budget (two ulongs): the summed SDF caps peak ~78
        float cNear = 1e9, cFar = -1e9;
        for (int mi = 0; mi < nMon; mi++) {
            GMonster m = mons[mi];
            float3 cc = float3(m.a.x, m.c.y + (m.b.w - m.c.x) * m.a.w, m.a.y);
            // Margin over the packed bound (which already encloses surface +
            // smin bleed): only needs to dominate the hit epsilon (0.0015) and
            // the normal-probe offset — a masked-out monster's surface never
            // lies ON the ray, so marching past it is harmless. Keeping it
            // small matters: at melee a drone's sphere gates most of the
            // screen's rays, and solid angle grows with R².
            float R = m.b.z * m.a.w + 0.05;
            float3 oc = ro - cc;
            float bq = dot(oc, rd);
            float hq = bq * bq - dot(oc, oc) + R * R;
            if (hq < 0.0) continue;
            float sq = sqrt(hq);
            float tEnter = -bq - sq, tExit = -bq + sq;           // roots of t^2 + 2*bq*t + c = 0
            if (tEnter > 64.0 || tExit < 0.0) continue;          // beyond march range / fully behind
            if (mi < 64) cmask.x |= (ulong(1) << ulong(mi));
            else if (mi < 128) cmask.y |= (ulong(1) << ulong(mi - 64));
            cNear = min(cNear, max(0.0, tEnter));
            cFar = max(cFar, tExit);
        }
        if (nMon > 128) { cmask = ulong2(~ulong(0)); cNear = 0.0; cFar = 64.0; }   // over the 128-instance mask budget: evaluate everything
        if (U.dbg.x > 0.5) { cmask = ulong2(~ulong(0)); cNear = 0.0; cFar = 64.0; }   // harness ground truth: the mask is a pure optimisation, so forcing it off must not change a pixel
        float t = 0.02; bool hit = false;
        for (int i = 0; i < 190; i++) {
            float3 p = ro + rd * t;
            ulong2 cm = (t >= cNear - 0.05 && t <= cFar + 0.05) ? cmask : ulong2(0);
            float d = sceneSDF(p, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cm);
            if (d < 0.0015) { hit = true; break; }
            float adv = d * 0.85;
            // Entering the creature window: outside it the field OMITS the
            // creature terms, so `d` says nothing about them — a wall-driven
            // step must never leap over the window's leading edge (a mine's
            // whole window is ~0.4: an open-room step clears it and the
            // object vanishes for that ray). Land ON the edge instead.
            // (dbg.y disables the clamp — harness-only, so the probe can prove
            // its instrument still detects the leap this clamp prevents)
            if (U.dbg.y < 0.5 && t < cNear - 0.05) adv = min(adv, cNear - 0.05 - t + 0.001);
            t += adv;
            if (t > 64.0) break;
        }

        float3 col;
        bool worldProj = false;   // the hit is a projectile orb (may pass IN FRONT of the viewmodel)
        if (hit) {
            float3 p = ro + rd * t;
            float3 n = calcNormal(p, dt, s, mapWH, ceilH, nMon, mons, shapes, fits, nFits, cmask);
            float2 ddp = dt.sample(s, p.xz / mapWH).rg;        // .r wall distance · .g pipe-routing enable
            float dWp = ddp.x, peP = ddp.y;
            float gd = min(min(dWp, min(p.y, ceilH - p.y)), wallPipes(p, dWp, ceilH, peP));   // grid incl. routed pipe
            float itemMat = 0.0; float creatureEmis = 0.0;
            float4 cf = (nMon > 0 && (cmask.x | cmask.y) != 0) ? creatureField(p, nMon, mons, shapes, cmask, itemMat, creatureEmis) : float4(0.0, 0.0, 0.0, 1e9);
            float3 alb; float emis = 0.0; bool reflective = false; bool isItem = false; bool isProj = false; bool isCreature = false; bool isProp = false; bool isDrum = false; bool isSocket = false; bool isMine = false;
            float rough = 0.7, metal = 0.0;   // PBR surface params, set per surface below
            if (cf.w < gd) {                                     // a creature / pickup / projectile / prop surface
                alb = cf.rgb;
                isItem = itemMat > 0.5 && itemMat < 1.5;         // c.z = 1 → pickup
                isProj = itemMat > 1.5 && itemMat < 2.5;         // c.z = 2 → glowing projectile orb
                worldProj = isProj;
                isProp = itemMat > 2.5 && itemMat < 3.5;         // c.z = 3 → static furniture / fixture
                isDrum = itemMat > 3.5 && itemMat < 4.5;         // c.z = 4 → fuel drum
                isSocket = itemMat > 4.5 && itemMat < 5.5;       // c.z = 5 → recharge socket
                isMine = itemMat > 5.5;                          // c.z = 6 → deployed mine
                isCreature = itemMat < 0.5;                      // c.z = 0 → living flesh
                if (isCreature) emis = creatureEmis;             // glowing ova / eyes (per-shape emissive)
                if (isProp) {                                    // MATTE battle-worn steel (low spec → not shiny plastic); a powered screen self-glows
                    rough = 0.82; metal = 0.12;
                    bool screen = dot(alb, float3(0.299, 0.587, 0.114)) > 0.95;   // the lit terminal stays clean + bright
                    if (!screen) {
                        float gr = fbm2(p.xz * 2.3 + p.y * 1.9);
                        alb *= 1.0 - 0.45 * smoothstep(0.40, 0.86, gr);             // soot/grime patches
                        float low = clamp(1.0 - p.y * 2.4, 0.0, 1.0);
                        float blood = smoothstep(0.62, 0.86, fbm2(p.xz * 1.7 + 12.0)) * low;
                        alb = mix(alb, float3(0.15, 0.02, 0.018), blood * 0.6);     // dried blood, pooled low
                        rough = clamp(0.72 + 0.3 * gr, 0.55, 0.97);                 // rough, matte, uneven — kills the sheen
                    } else {
                        // a LIVE terminal: scrolling LINES of amber text with CRT
                        // scanlines + flicker. Not independent random cells (those read
                        // as blobs) — glyphs come in WORD RUNS along each row (1D value
                        // noise → runs of lit cells with gaps), rows vary in density,
                        // some are blank (paragraph breaks) and a few flare as alerts.
                        // (p.y = up the screen; p.x+p.z = across the face, robust to
                        // the prop's yaw since the screen is vertical.)
                        float col = (p.x + p.z) * 34.0;
                        float row = floor(p.y * 52.0 + time * 4.0);                // rows scroll up
                        float rh = hash21(float2(row, 7.0));                       // per-line personality
                        float word = vnoise2(float2(col * 0.55 + rh * 90.0, row * 3.1));
                        float on = step(1.0 - (0.35 + 0.45 * rh), word);           // word runs; density per line
                        float kind = hash21(float2(row, 3.0));
                        on *= step(0.12, kind);                                    // ~12% blank lines
                        float alert = step(0.94, kind);                            // rare bright alert lines
                        float glyph = 0.55 + 0.45 * hash21(float2(floor(col), row));   // per-glyph sparkle
                        float scan = 0.80 + 0.20 * sin(p.y * 240.0);               // scanlines
                        float flick = 0.90 + 0.10 * sin(time * 36.0 + row * 1.7);
                        alb *= (0.22 + (0.85 + 0.75 * alert) * on * glyph) * scan * flick;
                    }
                    float lum = dot(alb, float3(0.299, 0.587, 0.114));
                    emis = smoothstep(1.0, 1.45, lum) * 2.4;                        // only the powered screen pushes past 1 → glows
                }
                // ground-contact AO on the OBJECT side: grounded bulk darkens toward
                // the deck (the floor discs below do the other half) — without this
                // a lit base rim floats everything visually
                if (!isItem && !isProj) alb *= 0.55 + 0.45 * smoothstep(0.0, 0.18, p.y);
                if (isDrum) {                                    // weathered industrial barrel — rusty, ribbed, matte
                    rough = 0.86; metal = 0.20;
                    float3 rust = float3(0.34, 0.15, 0.07);
                    // the flat steel lid sits a touch darker than the painted sides
                    alb = mix(alb, alb * 0.6, smoothstep(0.6, 0.9, n.y));
                    // two rolling hoops on the body (p.y = height up the drum, which
                    // stands flat on the deck — base y0, top ~0.45) — dark recessed bands
                    float rib = max(smoothstep(0.020, 0.0, abs(p.y - 0.15)),
                                    smoothstep(0.020, 0.0, abs(p.y - 0.32)));
                    alb *= 1.0 - 0.42 * rib;
                    float patch = fbm2(p.xz * 3.6 + p.y * 1.2);
                    alb = mix(alb, rust, smoothstep(0.46, 0.86, patch) * 0.72);     // mottled rust eating the paint
                    float streak = smoothstep(0.55, 0.95, fbm2(float2((p.x + p.z) * 6.5, p.y * 0.7 + 5.0)));
                    alb = mix(alb, rust * 0.6, streak * 0.5 * clamp(1.2 - p.y * 1.6, 0.25, 1.0));   // rust streaks bleed down
                    rough = clamp(0.78 + 0.20 * patch, 0.62, 0.97);
                }
                if (isSocket) {                                  // recharge pedestal — grimy steel + a self-glowing cell
                    bool litcell = dot(alb, float3(0.299, 0.587, 0.114)) > 0.95;
                    rough = 0.80; metal = 0.15;
                    if (!litcell) {
                        float gr = fbm2(p.xz * 2.6 + p.y * 1.7);
                        alb *= 1.0 - 0.40 * smoothstep(0.40, 0.85, gr);
                        rough = clamp(0.72 + 0.28 * gr, 0.58, 0.95);
                    } else {
                        alb *= 0.82 + 0.18 * sin(time * 4.0 + p.y * 10.0);          // the charged cell pulses gently
                    }
                    float lum = dot(alb, float3(0.299, 0.587, 0.114));
                    emis = smoothstep(1.0, 1.5, lum) * 2.6;                         // only the bright cell glows
                }
                if (isMine) {                                    // matte steel puck + a pulsing red trigger LED
                    rough = 0.6; metal = 0.2;
                    bool led = alb.r > 0.7 && alb.r > (alb.g + alb.b) * 1.5;        // the red lamp
                    if (led) emis = 1.6 + 1.4 * (0.5 + 0.5 * sin(time * 7.0));      // blinks so you spot it in the dark
                    else     alb *= 0.85;                                          // dark steel body
                }
                if (isCreature) {
                    rough = 0.34; metal = 0.0;                   // glossy WET CHITIN
                    // scaly micro-relief — breaks the gloss into wet organic scales
                    // (a smooth glossy SDF reads as PLASTIC; xenomorph hide is scaled)
                    float2 ua = float2(p.x + p.z, p.y - p.x) * 11.0;
                    float e = 0.5;
                    float gx = fbm2(ua + float2(e, 0.0)) - fbm2(ua - float2(e, 0.0));
                    float gy = fbm2(ua + float2(0.0, e)) - fbm2(ua - float2(0.0, e));
                    float3 t1 = normalize(cross(n, float3(0.0, 1.0, 0.0)) + float3(0.001, 0.0, 0.0));
                    float3 t2 = cross(n, t1);
                    n = normalize(n - (t1 * gx + t2 * gy) * 0.6);
                }
            } else {
                float dW = dWp;
                float dF = p.y, dC = ceilH - p.y;
                float dPipe = wallPipes(p, dW, ceilH, peP);
                // nearest CPU-placed fitting (valve/gauge), with part distances
                float dFit = 1e9; float3 fitParts = float3(1e9, 1e9, 0.0); float2 dialUV = float2(0.0, 0.0);
                float fitSeed = 0.0;
                for (int fi = 0; fi < nFits; fi++) {
                    float2 dq = p.xz - fits[fi].xy;
                    if (dot(dq, dq) > 0.36) continue;
                    float3 pp; float2 uv;
                    float fd = fittingDist(p, fits[fi], ceilH, pp, uv);
                    if (fd < dFit) { dFit = fd; fitParts = pp; dialUV = uv; fitSeed = fits[fi].x + fits[fi].y * 7.3; }
                }
                float dP = min(dPipe, dFit);
                int2 dim = int2(mapWH);
                if (dP <= dW && dP <= dF && dP <= dC) {          // ── BAKED WALL PIPE + FITTINGS ──
                    float along = p.x + p.z;                     // runs along the pipe (yaw-robust) for the grain
                    float rr = fbm2(float2(along * 3.0, p.y * 6.0));
                    if (dFit < dPipe) {
                        // ── a FITTING's surface — matched to the reference stopcock:
                        // worn steel body/bonnet/stem, RED-ENAMEL handwheel, and a
                        // proper instrument dial. Ownership is exact: the same SDF
                        // that marched the part says which part this is.
                        if (fitParts.x < 0.012) {                              // the handwheel
                            alb = mix(float3(0.58, 0.10, 0.07), float3(0.34, 0.05, 0.04), smoothstep(0.45, 0.9, rr));
                            rough = 0.52; metal = 0.2;
                        } else if (fitParts.y < 0.012) {                       // the gauge dial
                            float face = smoothstep(0.55, 0.85, length(n.xz)); // flat face vs rim
                            alb = mix(float3(0.24, 0.22, 0.19), float3(0.82, 0.80, 0.72), face);
                            if (face > 0.5) {
                                float2 dv = float2(dialUV.x, dialUV.y - 0.105);
                                float rd2 = length(dv);
                                if (rd2 > 0.028) alb = float3(0.20, 0.19, 0.17);               // bezel
                                else {
                                    float angg = atan2(dv.y, dv.x);
                                    if (rd2 > 0.021 && angg > 0.35 && angg < 2.79
                                        && fract((angg - 0.35) / 0.4886) < 0.16) {             // ticks
                                        alb = float3(0.22, 0.21, 0.19);
                                    }
                                    float na = mix(0.5, 2.6, pipeHash(fitSeed + 17.0));        // needle angle
                                    float2 nd = float2(cos(na), sin(na));
                                    float sN = dot(dv, nd), qN = fabs(dv.x * nd.y - dv.y * nd.x);
                                    if (sN > -0.006 && sN < 0.024 && qN < 0.0035) alb = float3(0.62, 0.10, 0.08);
                                }
                                if (rd2 < 0.006) alb = float3(0.10, 0.10, 0.11);               // centre pin
                            }
                            rough = 0.35; metal = 0.15;
                        } else {                                               // body, bonnet, stem, nut — worn steel
                            alb = mix(float3(0.52, 0.54, 0.57), float3(0.30, 0.31, 0.33), smoothstep(0.4, 0.9, rr));
                            rough = 0.45; metal = 0.7;
                        }
                    } else {
                        float3 copper = float3(0.62, 0.36, 0.26);    // drawn copper — warm against the iron walls
                        alb = mix(copper, float3(0.28, 0.15, 0.10), smoothstep(0.5, 0.9, rr) * 0.7);   // tarnish eating the shine
                        float drip = smoothstep(0.62, 0.95, fbm2(float2(along * 5.0, p.y * 0.8)));
                        alb = mix(alb, float3(0.16, 0.30, 0.24), drip * 0.35 * clamp(1.0 - dC * 2.2, 0.0, 1.0));   // verdigris weeping below
                        rough = clamp(0.30 + 0.40 * rr, 0.28, 0.75);  // polished where handled, dull where tarnished
                        metal = 0.85;                                 // copper is properly metallic
                    }
                } else if (dW <= dF && dW <= dC) {               // wall — id of the SOLID cell
                    int2 c = clamp(int2(floor(p.xz - n.xz * 0.5)), int2(0), dim - 1);
                    uint id = wallId.read(uint2(c)).r;
                    float along = (abs(n.x) > abs(n.z)) ? p.z : p.x;
                    // ── DOOR LEAF? A door plane lies strictly INSIDE its cell, so the
                    //   containing cell is the exact lookup (the half-step boundary
                    //   trick above can land in the open cell in front — especially
                    //   for the elevator, whose plane sits at the room-side face).
                    int2 cc = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint idc = wallId.read(uint2(cc)).r;
                    int nDoors = int(U.extra.w);
                    bool doorHit = false;
                    if (idc >= 12u && idc <= 18u && nDoors > 0) {
                        float part = 0.0, dflags = -1.0;
                        for (int di = 0; di < nDoors; di++) {
                            if (int(doorsB[di].x) == cc.x && int(doorsB[di].y) == cc.y) {
                                part = doorsB[di].z; dflags = doorsB[di].w; break;
                            }
                        }
                        if (dflags >= 0.0) {
                            doorHit = true;
                            bool slideX = (int(dflags) & 1) != 0;
                            bool edgeFace = slideX ? (abs(n.x) > abs(n.z)) : (abs(n.z) > abs(n.x));
                            if (edgeFace) {
                                // the leaf's exposed meeting edge (and the jamb reveal):
                                // machined dark steel, lightly brushed — never a stretched
                                // smear of the face texture
                                alb = float3(0.14, 0.145, 0.16)
                                    * (0.85 + 0.30 * fbm2(float2(p.y * 9.0, (p.x + p.z) * 2.0)));
                                rough = 0.45; metal = 0.6; emis = 0.0;
                            } else {
                                // LEAF-ANCHORED UVs: the texture rides the sliding panel.
                                // Each leaf has slid `gap` into its jamb, so the visible
                                // span maps back to the leaf's own half of the texture —
                                // the centre-seam artwork parts WITH the leaves instead of
                                // the panels sliding through a wall-anchored image.
                                float uLoc = fract(slideX ? p.x : p.z);
                                float gap = 0.5 * part;
                                float u = (uLoc < 0.5) ? (uLoc + gap) : (uLoc - gap);
                                alb = wallArr.sample(ts, float2(u, 1.0 - p.y), idc).rgb;
                                float2 wm = wallMaterial(idc); rough = wm.x; metal = wm.y;
                                // status lights / key bands / lamps glow; the slab doesn't
                                float strip = smoothstep(0.36, 0.54, dot(alb, float3(0.299, 0.587, 0.114)));
                                emis = wallEmissive(idc) * strip;
                            }
                            // doors are machined slabs: no bulkhead relief, no soot pass —
                            // they stay crisp (the grime/relief below is walls-only)
                        }
                    }
                    if (!doorHit) {
                    // texture u follows the face's RIGHT-HAND tangent, not the raw
                    // world axis — the raw axis runs backwards on two of the four
                    // wall orientations, mirroring anything written in the texture
                    // (the ARC seal read "ЯRA" on those faces). Noise never told.
                    float alongTex = (abs(n.x) > abs(n.z)) ? ((n.x > 0.0) ? -p.z : p.z)
                                                           : ((n.z > 0.0) ? p.x : -p.x);
                    alb = wallArr.sample(ts, float2(alongTex, 1.0 - p.y), id).rgb;
                    emis = wallEmissive(id);
                    // ── battle scarring ── only the EMBEDDED light (the bright
                    //   strip / screen) emits, fails and flickers — not the whole
                    //   bulkhead. Mask by texel brightness so the dark panel body
                    //   stays steady while just the fixture pulses or dies.
                    float screenGlass = 0.0;                    // lit-glass mask (screens / strip lights) — kept clean below
                    if (id == 4u) {
                        // litPanel strip light: only the bright strip emits, flickers, dies when busted
                        float strip = smoothstep(0.36, 0.54, dot(alb, float3(0.299, 0.587, 0.114)));
                        emis *= strip;
                        screenGlass = strip;
                        if (fixtureBusted(c)) { emis = 0.0; alb = mix(alb, alb * 0.30, strip); }
                        else emis *= fixtureFlicker(float2(c), time);
                    } else if (id == 10u) {
                        // COMPUTER BANK — live AMBER instrumentation. Each monitor of the 4×4
                        // grid renders a distinct TECHNICAL readout (scrolling code · oscilloscope
                        // · spectrum analyser · dashboard), varied per-monitor by hash, all
                        // monochrome amber on dark glass over a faint graticule — the classic
                        // phosphor-terminal look. Overrides the baked screen so content genuinely
                        // MOVES; pure time-driven math, negligible cost.
                        float2 g4 = float2(along, 1.0 - p.y) * 4.0;
                        float2 mcell = floor(g4);
                        float2 muv = fract(g4);
                        float mh = hash21(mcell), mh2 = hash21(mcell + 7.0);
                        float2 s = (muv - 0.09) / 0.82;            // screen glass inside the bezel, 0..1
                        bool onScreen = s.x > 0.0 && s.x < 1.0 && s.y > 0.0 && s.y < 1.0;
                        if (onScreen && !fixtureBusted(c)) {
                            float sp = 0.6 + 1.6 * mh2;            // per-monitor rate
                            float glow = 0.05 * (step(0.92, fract(s.x * 8.0)) + step(0.92, fract(s.y * 6.0)));  // faint graticule under everything
                            if (mh < 0.34) {                       // SCROLLING CODE / LOG — fine rows of ragged text
                                float ry = s.y * 13.0 + time * (1.3 + sp);
                                float row = floor(ry);
                                float len = 0.15 + 0.80 * hash21(float2(row, mcell.x + mcell.y * 3.0));         // per-line length
                                float ch = step(0.40, fract(s.x * 16.0 + hash21(float2(row, 2.0)) * 17.0));     // character cells
                                glow += 0.85 * ch * step(s.x, len) * step(0.20, fract(ry));                     // ragged lines, gaps between
                            } else if (mh < 0.56) {                // OSCILLOSCOPE — a complex trace on the grid
                                float y = 0.5 + 0.20 * sin(s.x * 16.0 + time * (3.0 + sp))
                                              + 0.09 * sin(s.x * 37.0 - time * (5.0 + sp));
                                glow += 1.0 - smoothstep(0.0, 0.035, abs(s.y - y));
                            } else if (mh < 0.78) {                // SPECTRUM ANALYSER — many thin bars
                                float bar = floor(s.x * 14.0);
                                float h = 0.12 + 0.80 * pow(0.5 + 0.5 * sin(time * (2.4 + sp) + bar * 0.8 + mh * 6.0), 2.0);
                                glow += 0.85 * step(s.y, h) * step(0.28, fract(s.x * 14.0));
                            } else {                               // DASHBOARD — bar meters / scrolling values / mini-scope
                                if (s.y > 0.64) {                  // two segmented bar meters (top)
                                    float meter = (s.y > 0.82) ? 0.45 + 0.45 * sin(time * (1.4 + sp))
                                                               : 0.30 + 0.55 * fract(time * 0.35 + mh);
                                    glow += 0.85 * step(s.x, meter) * step(0.10, fract(s.x * 26.0));
                                } else if (s.y > 0.28) {           // scrolling numeric rows (middle)
                                    float row = floor(s.y * 8.0 + time * (0.8 + sp));
                                    glow += 0.80 * step(0.50, fract(s.x * 18.0 + row * 4.0)) * step(s.x, 0.92);
                                } else {                           // a mini oscilloscope strip (bottom)
                                    glow += 1.0 - smoothstep(0.0, 0.03, abs(s.y - (0.14 + 0.09 * sin(s.x * 26.0 + time * 4.0))));
                                }
                            }
                            glow *= 0.9 + 0.15 * fixtureFlicker(float2(c), time);
                            if (U.dbg.z > 0.0) glow *= 0.40 + 0.60 * step(0.40, fract(time * 20.0 + mh * 3.1));  // fault stutter
                            glow = clamp(glow, 0.0, 1.4);
                            float3 amber = float3(1.0, 0.66, 0.15);
                            alb = mix(float3(0.035, 0.022, 0.010), amber, min(1.0, glow));   // dark amber glass → bright amber content
                            emis = glow * 2.3;                                               // self-lit; blooms + mirrors in the wet floor
                            screenGlass = 1.0;
                        } else {
                            alb = fixtureBusted(c) ? float3(0.04, 0.04, 0.045) : float3(0.09, 0.10, 0.12);   // dark steel bezel (darker if dead)
                            emis = 0.0;
                        }
                    }
                    float dirt = 1.0 - screenGlass;             // powered glass stays clean (matches the desk terminals)
                    if (id == 8u || id == 9u) dirt *= 0.3;      // battle soot belongs to burned steel — bare rock takes far less
                    if (id == 19u) dirt = 0.0;                  // a lift car keeps its machined finish — it's a steel box, not a battlefield
                    float low = clamp(1.0 - p.y * 1.3, 0.0, 1.0);
                    float scorch = smoothstep(0.42, 0.78, fbm2(float2(along * 1.3, p.y * 1.4))) * (0.45 + 0.55 * low);
                    alb *= 1.0 - 0.82 * scorch * dirt;                         // sooty patches, heavier low
                    float streak = smoothstep(0.5, 0.92, fbm2(float2(along * 5.3, p.y * 0.5 + 11.0))) * clamp(p.y, 0.0, 1.0);
                    alb = mix(alb, alb * float3(0.52, 0.47, 0.42), streak * 0.6 * dirt);   // grime bleeding down
                    float blood = smoothstep(0.55, 0.82, fbm2(float2(along * 2.1 + 7.0, p.y * 1.9))) * clamp(1.3 - p.y * 2.2, 0.0, 1.0);
                    alb = mix(alb, float3(0.2, 0.03, 0.022), blood * 0.85 * dirt);    // dried blood up the base
                    // material + micro-relief — a grimy-iron sheen, with grain
                    // breaking up the highlight (was flat, matte, light-frozen)
                    float2 wm = wallMaterial(id); rough = wm.x; metal = wm.y;
                    // worn metal is never uniformly shiny: patchy wear drives the
                    // roughness, so what sheen remains breaks into smudges and
                    // hand-polished spots instead of one clean plastic highlight
                    float wear = fbm2(float2(along * 1.7 + 23.0, p.y * 2.2));
                    rough = clamp(rough + (wear - 0.35) * 0.55, 0.15, 0.95);
                    if (id == 8u || id == 9u) {
                        // ── the depths: rock face, not bulkhead ── hewn/blasted stone
                        //   gets NO panel seams or ribs (a manufactured groove grid
                        //   sliced across the strata and the caverns read as plant
                        //   rooms). Instead: big strata swings in the albedo so the
                        //   headlamp can't bleach it flat, a normal that lurches over
                        //   blast-scale lumps, thin crack veins, and crevice shadow.
                        float3 tU = (abs(n.x) > abs(n.z)) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
                        float2 ruv = float2(along, p.y);
                        alb *= 0.34 + 0.48 * fbm2(ruv * 0.7 + 3.0);                      // strata light/dark sweeps (and an overall drop — rock, not plaster)
                        n = bumpNormal(ruv, n, tU, float3(0.0, 1.0, 0.0), 0.9, 1.8);     // blast lumps
                        n = bumpNormal(ruv, n, tU, float3(0.0, 1.0, 0.0), 3.1, 0.5);     // fracture detail
                        float ridge = 1.0 - abs(2.0 * fbm2(ruv * 1.9 + 17.0) - 1.0);     // ridged noise: its crest-lines read as
                        float crack = smoothstep(0.86, 0.97, ridge);                     //   thin dark VEINS, not blotches
                        alb *= 1.0 - 0.60 * crack;
                        float crev = smoothstep(0.62, 0.88, fbm2(ruv * 1.4 + 17.0));
                        alb *= 1.0 - 0.35 * crev;                                        // hollow shadow between lumps
                        if (id == 9u) {                              // rock + struts: the bolted steelwork survives
                            float ribLit = 1.0 - smoothstep(0.40, 0.50, abs(fract(along * 0.5) - 0.5));
                            alb = mix(alb, alb * 1.45 + float3(0.05), ribLit * 0.5);
                        }
                        // ── seepage ── ground water weeps down the rock in streaks:
                        //   dark and cool where it runs, glass-smooth where the film
                        //   sits, so the headlamp glints off wet stone. Stronger toward
                        //   the floor (it runs down and pools there — see puddleField).
                        float seep = smoothstep(0.50, 0.78, fbm2(float2(along * 2.6 + 5.0, p.y * 0.25)))
                                   * clamp(1.15 - p.y * 0.55, 0.0, 1.0)
                                   * (id == 8u ? 1.0 : 0.55);        // bare rock weeps more than strutted
                        alb = mix(alb, alb * float3(0.42, 0.46, 0.50), seep);            // soaked stone: darker, a shade cool
                        rough = mix(rough, 0.12, seep);
                    } else if (id != 10u && (id < 12u || id > 19u)) {
                        // ── structural depth ── recessed bulkhead panels + raised steel
                        //   ribs: grooves read darker (recessed), ribs as brighter steel,
                        //   and the normal follows the relief so the flat wall has DEPTH.
                        //   (Skipped on a terminal bank — its structure IS the monitor
                        //   grid — and on door/elevator faces, which are machined slabs;
                        //   grooves would slice through the screens/leaves.)
                        float3 tU = (abs(n.x) > abs(n.z)) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
                        float2 ruv = float2(along, p.y);
                        float panelLit = smoothstep(0.04, 0.12, abs(fract(along * 2.0) - 0.5))
                                       * smoothstep(0.04, 0.12, abs(fract(p.y * 2.0) - 0.5));
                        alb *= 0.5 + 0.5 * panelLit;                               // grooves recessed (darker)
                        float ribLit = 1.0 - smoothstep(0.40, 0.50, abs(fract(along * 0.5) - 0.5));
                        alb = mix(alb, alb * 1.45 + float3(0.05), ribLit * 0.5);   // ribs catch as proud steel
                        float re = 0.03;
                        float rdu = wallRelief(ruv + float2(re, 0.0)) - wallRelief(ruv - float2(re, 0.0));
                        float rdv = wallRelief(ruv + float2(0.0, re)) - wallRelief(ruv - float2(0.0, re));
                        n = normalize(n - (tU * rdu + float3(0.0, 1.0, 0.0) * rdv) * 0.85);   // relief shapes the normal
                        n = bumpNormal(float2(along, p.y), n, tU, float3(0.0, 1.0, 0.0), 2.6, 0.12 * smoothstep(0.15, 0.55, rough));   // + fine grain
                    }
                    }   // !doorHit — generic wall path ends
                } else if (dF <= dC) {                           // floor
                    int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint id = floorId.read(uint2(c)).r;
                    alb = flatArr.sample(ts, p.xz, id).rgb;
                    emis = flatEmissive(id);
                    bool liquid = (id == 3u || id == 8u);        // nukage / blood pools — liquid at any depth
                    float wet = max(U.extra.y, liquid ? 1.0 : 0.0);   // the lowest floor floods (extra.y); pools always wet
                    if (!liquid && id == 7u && wet < 0.01) {
                        // ── puddles ── the rock floors above the flood line: water
                        //   finds its way down, so floor 7 doesn't drown — it pools.
                        //   The shared CPU/GPU field says where (the game wades and
                        //   drips in the same water), with a damp soaked-in margin
                        //   ringing each pool.
                        float pf = puddleField(p.xz + U.env.xy);
                        float pool = puddleMask(pf);
                        float damp = smoothstep(0.36, 0.50, pf) * (1.0 - pool);
                        alb *= 1.0 - 0.22 * damp;                // wet rock rings the standing water
                        wet = pool;
                    }
                    reflective = wet > 0.01;                     // a dry industrial deck does NOT mirror
                    float2 fm = flatMaterial(id); rough = fm.x; metal = fm.y;
                    // decades of boot traffic: patchy wear dulls the deck unevenly
                    float wearF = fbm2(p.xz * 1.9 + 41.0);
                    rough = clamp(rough + (wearF - 0.35) * 0.5, 0.15, 0.95);
                    if (liquid) {                                // hazard pool — live rippling surface
                        // organic, non-repeating ripples: two layers of FLOWING value
                        // noise at incommensurate speeds/directions (was two crossed
                        // sines → an obvious uniform grid). The normal follows the
                        // noise gradient, so the surface churns like a real liquid.
                        float2 q = p.xz;
                        float2 w1 = q * 3.1 + float2(time * 0.55, time * -0.41);
                        float2 w2 = q * 6.9 + float2(time * -0.33, time * 0.49);
                        float e = 0.09;
                        float gx = (fbm2(w1 + float2(e, 0.0)) - fbm2(w1 - float2(e, 0.0)))
                                 + 0.5 * (fbm2(w2 + float2(e, 0.0)) - fbm2(w2 - float2(e, 0.0)));
                        float gz = (fbm2(w1 + float2(0.0, e)) - fbm2(w1 - float2(0.0, e)))
                                 + 0.5 * (fbm2(w2 + float2(0.0, e)) - fbm2(w2 - float2(0.0, e)));
                        n = normalize(n + float3(gx, 0.0, gz) * 2.4);   // churning ripples from flowing noise
                        if (id == 3u) {                          // nukage glow — pulses irregularly, not a clean sine
                            float pulse = fbm2(q * 1.6 + float2(time * 0.5, time * 0.37));
                            emis *= 0.5 + 1.0 * pulse;
                        }
                        alb *= 0.55;
                        rough = 0.10; metal = 0.0;               // a glassy hazard-liquid surface
                    } else if (wet > 0.01) {                     // standing water — the drowned floor 8, floor 7's pools
                        float2 q = p.xz;
                        n = normalize(n + float3(cos(q.x * 5.1 + time * 1.1), 0.0,
                                                 cos(q.y * 4.7 - time * 1.3)) * (0.14 * wet));   // slow standing-water ripples
                        alb = mix(alb, alb * float3(0.30, 0.34, 0.42), wet);   // water darkens the bed under it, and cools it — reads liquid, not wet sand
                        rough = mix(rough, 0.08, wet); metal = 0.0;   // standing water glazes the deck glossy
                    } else {                                     // DRY industrial deck
                        if (id == 7u) {                          // bare rock floor: strata sweeps, like the walls —
                            alb *= 0.50 + 0.45 * fbm2(p.xz * 0.8 + 27.0);   // never a flat bleached pan under the headlamp
                        }
                        if (id != 2u) {                          // soot + dried blood (not the open grates)
                            float fscorch = smoothstep(0.46, 0.82, fbm2(p.xz * 1.9 + 40.0));
                            alb *= 1.0 - 0.62 * fscorch;
                            float fblood = smoothstep(0.56, 0.84, fbm2(p.xz * 1.5 + 21.0));
                            alb = mix(alb, float3(0.17, 0.024, 0.02), fblood * 0.72);
                        }
                        // micro-relief on the deck — tread / grain catches the lamps
                        n = bumpNormal(p.xz, n, float3(1.0, 0.0, 0.0), float3(0.0, 0.0, 1.0), 2.2, 0.09);
                    }
                    // located damage — blood at exact kill sites, scorch under
                    // corpses that burned out (a runtime world-space decal channel,
                    // stamped by gameplay events rather than baked from the cell hash)
                    // ── CONTACT SHADOWS ── the grid-only AO can't see the SDF
                    //   objects, so lit floor ran straight under drums / props /
                    //   corpses and they all read as FLOATING. A soft occlusion
                    //   disc under each object's bulk plants everything on the
                    //   deck. Objects hovering above the floor (bobbing pickups,
                    //   projectiles) shadow proportionally less.
                    // (distance-gated: this is O(floor pixels × objects) and it was
                    // measurably heating the GPU — contact shadows are unreadable
                    // beyond ~14 units anyway, and a cheap box-reject skips the
                    // maths for every object that isn't near this pixel)
                    if (t < 14.0) {
                        for (int mi = 0; mi < nMon; mi++) {
                            GMonster mm = mons[mi];
                            // a CONTACT shadow hugs the footprint — wide discs read as
                            // the shadow of something hovering, the opposite of the goal
                            float groundR = mm.b.z * mm.a.w * 0.55;
                            float2 dxz = p.xz - mm.a.xy;
                            if (abs(dxz.x) > groundR || abs(dxz.y) > groundR) continue;
                            float dr2 = dot(dxz, dxz) / max(groundR * groundR, 0.0025);
                            if (dr2 >= 1.0) continue;
                            float dr = sqrt(dr2);
                            float hover = clamp(1.0 - mm.c.y * 2.0, 0.0, 1.0);
                            alb *= 1.0 - 0.6 * hover * (1.0 - dr) * (1.0 - dr);
                        }
                    }
                    int nD = int(U.extra.x);
                    if (nD > 0 && id != 2u && id != 3u && id != 8u) {
                        float dn = 0.5 + 0.5 * fbm2(p.xz * 3.3 + 5.0);          // one irregular-edge sample, shared
                        for (int di = 0; di < nD; di++) {
                            float4 dc = decals[di];
                            float rr = length(p.xz - dc.xy) / max(dc.z, 0.05);
                            if (rr >= 1.0) continue;
                            float edge = 1.0 - smoothstep(0.15, 1.0, rr);
                            float fall = edge * (0.62 + 0.38 * dn);             // solid core, noise erodes the rim
                            if (dc.w > 2.0) {
                                // SMOLDERING ASH (strength w−2) — a burned-out corpse:
                                // chunky charcoal patches, live embers glowing in the
                                // thickest lumps and flickering as they die. Flat — the
                                // marine walks straight over what's left.
                                float st = clamp(dc.w - 2.0, 0.0, 1.0);
                                float lump = vnoise2(p.xz * 26.0);
                                float ash = smoothstep(0.45, 0.70, lump) * fall * st;
                                alb = mix(alb, float3(0.07, 0.065, 0.06), min(1.0, ash * 1.8));
                                float fleck = smoothstep(0.80, 0.95, lump) * fall * st;
                                float glowT = 0.55 + 0.45 * sin(time * 2.3 + lump * 37.0);
                                alb = mix(alb, float3(0.9, 0.35, 0.08), fleck * glowT * 0.8);
                                emis += fleck * glowT * 0.5;
                            }
                            else if (dc.w >= 0.0) alb *= 1.0 - 0.93 * fall * dc.w;    // scorch → charred black
                            else if (dc.w > -2.0) { float b = clamp(fall * (-dc.w) * 1.1, 0.0, 1.0);   // blood → dark wet pool
                                   alb = mix(alb, float3(0.13, 0.014, 0.011), b); }
                            else {
                                // OFFAL (w < -2, strength = -(w+2)) — a gibbed drone's
                                // remains as a CHUNKY mask: noise cells read as strewn
                                // meat lumps, the thickest glisten wet. Flat geometry,
                                // so it reads right at any scale and angle — solids for
                                // gore kept rendering as furniture.
                                float st = clamp(-(dc.w + 2.0), 0.0, 1.0);
                                float lump = vnoise2(p.xz * 22.0);
                                float meat = smoothstep(0.55, 0.75, lump) * fall * st;
                                alb = mix(alb, float3(0.30, 0.035, 0.03), min(1.0, meat * 1.7));
                                float glisten = smoothstep(0.74, 0.92, lump) * fall * st;
                                alb = mix(alb, float3(0.52, 0.10, 0.08), glisten);
                            }
                        }
                    }
                } else {                                         // ceiling + recessed lamp housings
                    int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint id = ceilId.read(uint2(c)).r;
                    alb = flatArr.sample(ts, p.xz, id).rgb;
                    float2 cm = flatMaterial(id); rough = cm.x; metal = cm.y;
                    rough = clamp(rough + (fbm2(p.xz * 1.6 + 67.0) - 0.35) * 0.4, 0.15, 0.95);   // patchy age
                    bool lamp = isLampCell(c);
                    if (id == 6u) {
                        // stone ceiling — the blasted roof of the working, not a hung
                        // tech grid: strata sweeps, lumpy relief, crack veins, and only
                        // the odd strung work-light (most lamp sockets never made it
                        // this deep)
                        alb *= 0.34 + 0.48 * fbm2(p.xz * 0.7 + 9.0);
                        n = bumpNormal(p.xz, n, float3(1.0, 0.0, 0.0), float3(0.0, 0.0, 1.0), 1.1, 1.4);
                        float ridge = 1.0 - abs(2.0 * fbm2(p.xz * 1.9 + 23.0) - 1.0);
                        alb *= 1.0 - 0.60 * smoothstep(0.86, 0.97, ridge);
                        float crev = smoothstep(0.62, 0.88, fbm2(p.xz * 1.6 + 23.0));
                        alb *= 1.0 - 0.35 * crev;
                        lamp = lamp && (ihash(c.x, c.y) % 3u) == 0u;
                    }
                    // a lamp sits in every other open ceiling cell (the cell over a
                    // ceiling point is always open), so lamps follow the layout
                    if (lamp) {
                        float2 ctr = float2(c) + 0.5;
                        float m = max(abs(p.x - ctr.x), abs(p.z - ctr.y));   // 0..0.5
                        if (m < LAMP_HALF) {
                            float face = 1.0 - smoothstep(LAMP_HALF * 0.42, LAMP_HALF, m);   // long soft edge, not a hard square
                            alb = mix(float3(0.06, 0.06, 0.08), LAMP_WARM, face);   // dark housing → warm face
                            emis = 7.5 * U.tune.x * face * fixtureFlicker(float2(c), time);   // HDR — blooms + mirrors in the wet floor (tune.x = overhead dimmer)
                        }
                    }
                }
            }
          if (isProj) {
            // glowing energy orb: a hot near-white core fading out to the bolt's
            // colour, bright enough to bloom — every projectile now reads like the
            // plasma did, in-kernel (lit + occluded), not a flat composited sprite
            float facing = max(0.0, dot(n, -rd));
            float3 core = mix(alb, float3(1.0, 0.98, 0.95), pow(facing, 4.0) * 0.5);   // white only at the very centre
            col = core * (1.3 + 2.3 * facing) * exp(-t * 0.02);                        // colour-saturated glow, blooms
          } else if (isItem) {
            // pickups SIT IN THE WORLD — lit mostly by the room light + the marine's
            // own headlamp (like everything else he sees), not a self-floodlit floating
            // beacon. Only a faint rim + a touch of self-glow on the very brightest
            // detail keep them findable in the dark, without making them pop out.
            float3 room = clamp(lightTex.sample(s, p.xz / mapWH).rgb, 0.25, 1.0);
            float3 kd = normalize(float3(0.4, 0.85, 0.3));
            float key = 0.20 + 0.40 * max(0.0, dot(n, kd));        // gentle ambient key (was a strong floodlight)
            // headlamp — a pickup brightens when the beam falls on it, matching the world
            float3 toH = ro - p; float hd = length(toH);
            float3 Lh = hd > 1e-4 ? toH / hd : float3(0.0, 1.0, 0.0);
            float beam = smoothstep(0.40, 0.88, dot(-Lh, U.fwd.xyz)) * max(0.0, 1.0 - hd / 8.5);
            float ndl = max(0.0, dot(n, Lh));
            float rim = pow(1.0 - max(0.0, dot(n, -rd)), 3.0);
            float3 lit = alb * key * room + alb * (ndl * beam * 0.85) + alb * rim * 0.12;
            // selective self-glow: only the brightest detail (energy cells, keycards)
            // glows now, and gently — the rest just sits in the room
            float gl = max(0.0, max(alb.r, max(alb.g, alb.b)) - 0.95);
            lit += alb * gl * 1.3;
            col = lit * exp(-t * 0.032);
          } else {
            float3 sect = min(lightTex.sample(s, p.xz / mapWH).rgb, float3(1.0));  // baked sector light (clamped)
            // the flat fill keeps its brightness but sheds most of its SATURATION —
            // colour is the point lights' job now, directionally; a fixture no longer
            // washes its whole room one hue through the baked bleed.
            float secLum = dot(sect, float3(0.30, 0.59, 0.11));
            float3 sectFill = mix(float3(secLum), sect, 0.5);
            float ao = calcAO(p, n, dt, s, mapWH, ceilH);
            float3 V = -rd;
            float3 f0 = mix(float3(0.04), alb, metal);           // dielectric 4% → metallic = albedo-tinted
            float3 diffAlb = alb * (1.0 - 0.6 * metal);          // grimy metals keep some diffuse (not pure)
            if (isCreature) { diffAlb = alb * 0.15; f0 = float3(0.09); }   // NEAR-BLACK body (survives bright light); the wet scaly highlights + rim do the modelling
            // hemisphere-tinted ambient: cool on up-facing, warm bounce underneath
            float hemiUp = 0.5 + 0.5 * n.y;
            float3 ambTint = mix(float3(0.82, 0.90, 1.06), float3(1.08, 0.97, 0.82), hemiUp);
            // ── auto-headlamp: the marine's helmet lamp — a cool LED forward CONE
            //    (+ a small feet-spill) whose gain ramps with how dark the cell he
            //    stands in is: it idles in lit rooms and does the seeing in unlit
            //    ones. Matches the raycaster's lamp (reach 8.5, ~28° inner/66° outer).
            const float3 LAMP = float3(\(WorldLight.lampColor.x), \(WorldLight.lampColor.y), \(WorldLight.lampColor.z));   // = WorldLight.lampColor (single source of truth)
            float3 toH = ro - p; float hd = length(toH);         // lamp at the eye
            float3 Lh = hd > 1e-4 ? toH / hd : float3(0.0, 1.0, 0.0);
            float cosA = dot(-Lh, U.fwd.xyz);                    // angle off the beam axis
            float cone = smoothstep(0.40, 0.88, cosA);           // ~66° outer → ~28° inner, soft edge
            float distF = max(0.0, 1.0 - hd / 8.5);
            float feet = hd < 2.2 ? (1.0 - hd / 2.2) : 0.0;      // omni spill at the marine's feet
            float beam = cone * distF * distF + 0.6 * feet * feet;
            // auto-gain from the baked light the marine is standing in. Kept clearly
            // PRESENT everywhere (high floor) and ramped further up in true darkness —
            // the GPU scene carries far more competing light than the raycaster
            // (emitter point lights + lamp pools), so a lamp that idled like the
            // raycaster's just vanished. This reads as the marine's own beam.
            float plum = dot(min(lightTex.sample(s, ro.xz / mapWH).rgb, float3(1.0)), float3(0.299, 0.587, 0.114));
            float lampGain = (0.55 + 0.45 * clamp((0.62 - plum) / 0.50, 0.0, 1.0)) * 1.6;
            float3 head = LAMP * (lampGain * beam);
            float ndl = max(0.0, dot(n, Lh));
            float3 lit = diffAlb * sectFill * ambTint * 0.26 * ao   // dim, desaturated flat fill — point lights carry the key
                       + (diffAlb * ndl + specBP(n, V, Lh, rough, f0)) * head;
            if (isCreature) lit += diffAlb * (pow(max(0.0, dot(V, -Lh)), 2.0) * 0.5 * ao) * head;   // flesh backscatter
            lit += alb * emis;                                   // emissive surfaces glow
            // warm pooled downlight from the nearest ceiling lamp (over an open
            // cell) — gives rooms their lit pools without baking per-lamp lights
            {
                // sum the nearby ceiling lamps (3×3 grid of lamp cells) so their
                // pools OVERLAP into smooth falloff instead of hard per-cell squares
                int2 dim2 = int2(mapWH);
                int lx0 = (int(floor(p.x)) / 2) * 2, lz0 = (int(floor(p.z)) / 2) * 2;   // even = lamp cells
                float3 pool = float3(0.0), poolSpec = float3(0.0);
                for (int dz = -2; dz <= 2; dz += 2) {
                    for (int dx = -2; dx <= 2; dx += 2) {
                        int cx = lx0 + dx, cz = lz0 + dz;
                        if (cx < 0 || cz < 0 || cx >= dim2.x || cz >= dim2.y) continue;
                        if (wallId.read(uint2(uint(cx), uint(cz))).r != 0u) continue;   // lamp only over open cell
                        float3 tl = float3(float(cx) + 0.5, ceilH - 0.04, float(cz) + 0.5) - p;
                        float d2 = dot(tl, tl), dl = sqrt(d2);
                        float3 Ld = tl / dl;
                        float nl = max(0.0, dot(n, Ld));
                        float atn = 1.0 / (1.0 + d2 * 2.6);    // tighter pools → dark between lamps in open rooms
                        float fdrop = fixtureFlicker(float2(float(cx), float(cz)), time);
                        // directional pool on floors + a soft omni term so walls near
                        // a lamp brighten and fall off with distance
                        pool += LAMP_WARM * ((1.9 * nl + 0.5) * atn * fdrop);
                        poolSpec += specBP(n, V, Ld, rough, f0) * LAMP_WARM * (atn * fdrop);   // metallic glints under the lamps
                    }
                }
                lit += (diffAlb * pool + poolSpec) * ao * 0.42 * U.tune.x;   // warm pools + spec (tune.x dims the overheads); the colored sector field leads
            }
            // dynamic + emitter lights — the dramatic shaded point lights raking
            // the walls (warm keys, teal/red fills) plus muzzle flash + projectiles.
            // Only the leading `nShadow` (the bright keys) cast a soft shadow — the
            // colour fills are unshadowed, cheap, exactly like the beauty proof.
            int nL = int(U.grid.w);
            int nShadow = int(U.extra.z);
            for (int li = 0; li < nL; li++) {
                float3 tl = lights[li].posR.xyz - p;
                float d2 = dot(tl, tl);
                float f = 1.0 - d2 * lights[li].posR.w;
                if (f <= 0.0) continue;
                float dl = sqrt(d2);
                float3 Ld = tl / dl;
                float3 lcol = lights[li].colI.rgb * (lights[li].colI.w * f * f);
                // flesh sub-surface backscatter — strongest when the light is BEHIND
                // the creature (translucent rim glow), so it's taken before the
                // front-face cull and left unshadowed (light transmits through flesh)
                if (isCreature) lit += diffAlb * (pow(max(0.0, dot(V, -Ld)), 2.0) * 0.5 * ao) * lcol;
                float nl = max(0.0, dot(n, Ld));
                if (nl <= 0.0) continue;
                float shd = (li < nShadow)
                    ? softShadow(p + n * 0.02, Ld, dl - 0.05, 18.0, dt, s, mapWH, ceilH)   // keys: soft, full occlusion
                    : wallBlocked(p + n * 0.02, Ld, dl - 0.05, dt, s, mapWH);              // fills: cheap wall/door occlusion (no cross-door bleed)
                if (shd <= 0.0) continue;
                lit += (diffAlb * nl + specBP(n, V, Ld, rough, f0)) * lcol * shd;
            }
            // wet-floor reflection — one grid-only bounce, Fresnel-weighted
            if (reflective) {
                float3 R = reflect(rd, n);
                float3 rc = reflectShade(p + n * 0.02, R, dt, s, ts, mapWH, ceilH, lightTex,
                                         wallArr, flatArr, wallId, floorId, ceilId);
                float fres = mix(0.22, 0.90, pow(1.0 - max(0.0, dot(n, -rd)), 4.0));   // a genuinely wet, reflective floor
                lit = mix(lit, rc, fres);
            }
            // keep the creature a DARK, MENACING threat. The flat room light (ambient
            // + lamp pools + headlamp) was washing the carapace pale — "blancmange",
            // not the locked dark look. So pull the lit body down hard into shadow,
            // keep a cold WET rim on the silhouette, and bleed deep red into the
            // crevices (organic-SDF "bleed"): a glistening threat in the dark, not a
            // brightly-lit blob. (The raycaster gets this for free from its baked sprite.)
            float3 creatureEdge = float3(0.0);
            if (isCreature) {
                // A cold WET silhouette rim — wider and brighter than before, and
                // (below) added AFTER the aerial falloff, scaled UP with distance, so
                // the outline READS at any range and in the dark: a glistening threat
                // emerging from black, not a creature that vanishes ten cells away.
                // The body itself stays dark (diffAlb already pulled it down) — the
                // edge does the reading, so it never becomes a brightly-lit blob.
                float rim = pow(1.0 - max(0.0, dot(n, V)), 2.2);
                creatureEdge = rim * float3(0.34, 0.46, 0.58) * (0.5 + 0.5 * ao);     // self-lit cold wet edge
                lit += float3(0.10, 0.009, 0.007) * (1.0 - ao) * 0.5;                 // faint sub-surface bleed
            }
            col = lit * exp(-t * 0.032);                         // aerial falloff into dread-dark
            // the silhouette is distance-stable: strengthen it the farther the
            // creature is, exactly countering the body's fade so it never disappears.
            if (isCreature) col += creatureEdge * mix(0.55, 1.30, clamp(t / 14.0, 0.0, 1.0));
          }
        } else {
            col = float3(0.010, 0.012, 0.020);
        }
        // ── the marine's weapon ── the viewmodel overlay: marched in gun-local
        // space AFTER the world resolves (never swallowed by geometry), then
        // shaded by the same rig — sector fill, ceiling-lamp pools, dynamic
        // lights, headlamp — so the weapon sits IN the scene, not on top of it.
        float volT = hit ? t : 28.0;
        float vmDepth = -1.0;   // >0 where the gun draws → the gun owns the depth, so nothing (mesh/particles) composites over it
        int vmN = int(U.env.w);
        if (vmN > 0) {
            int vmStart = int(U.env.z);
            float3 rN = normalize(U.right.xyz);
            float3 rel = ro - U.vmA.xyz;
            float3 rol = float3(dot(rel, rN), rel.y, dot(rel, U.fwd.xyz));
            float3 rdl = float3(dot(rd, rN), rd.y, dot(rd, U.fwd.xyz));
            float3 oc = rol - U.vmB.xyz;                 // bound-sphere gate (local)
            float bq = dot(oc, rdl), cc = dot(oc, oc) - U.vmA.w * U.vmA.w;
            float disc = bq * bq - cc;
            if (disc > 0.0) {
                float sq = sqrt(disc);
                float tvOut = -bq + sq;
                float tv = max(0.01, -bq - sq);
                bool vhit = false; float emv = 0.0;
                for (int i = 0; i < 48 && tv < tvOut; i++) {
                    float4 f = vmField(rol + rdl * tv, shapes, vmStart, vmN, emv);
                    if (f.w < 0.0012) { vhit = true; break; }
                    tv += f.w * 0.9;
                }
                // a projectile orb NEARER than the gun keeps the pixel: the
                // bolt must be seen leaving the muzzle, or close-range fire
                // has no visual at all. Everything else loses to the weapon
                // (walls never swallow the marine's own gun).
                if (vhit && worldProj && hit && t < tv) vhit = false;
                if (vhit) {
                    float3 pl = rol + rdl * tv;
                    float eN; float2 e2 = float2(0.0015, 0.0);
                    float3 nl = normalize(float3(
                        vmField(pl + e2.xyy, shapes, vmStart, vmN, eN).w - vmField(pl - e2.xyy, shapes, vmStart, vmN, eN).w,
                        vmField(pl + e2.yxy, shapes, vmStart, vmN, eN).w - vmField(pl - e2.yxy, shapes, vmStart, vmN, eN).w,
                        vmField(pl + e2.yyx, shapes, vmStart, vmN, eN).w - vmField(pl - e2.yyx, shapes, vmStart, vmN, eN).w));
                    float4 f = vmField(pl, shapes, vmStart, vmN, emv);
                    float3 p = ro + rd * tv;             // world-space hit (rdl is unit: local t == world t)
                    float3 n = normalize(rN * nl.x + float3(0.0, 1.0, 0.0) * nl.y + U.fwd.xyz * nl.z);
                    float3 V = -rd;
                    float3 alb = f.rgb;
                    float rough = 0.42, metal = 0.55;    // hard-worn gunmetal — keeps its diffuse colour
                    float3 f0 = mix(float3(0.04, 0.04, 0.04), alb, metal);
                    float3 diffAlb = alb * (1.0 - metal * 0.7);
                    float3 sectFill = min(lightTex.sample(s, p.xz / mapWH).rgb, float3(1.4, 1.4, 1.4));
                    float hemiUp = 0.5 + 0.5 * n.y;
                    float3 ambTint = mix(float3(0.82, 0.90, 1.06), float3(1.08, 0.97, 0.82), hemiUp);
                    float3 lit = diffAlb * sectFill * ambTint * 0.52;
                    // the marine's own headlamp grazes the weapon from the eye
                    float ndl = max(0.0, dot(n, V));
                    lit += (diffAlb * ndl + specBP(n, V, V, rough, f0)) * float3(\(WorldLight.lampColor.x), \(WorldLight.lampColor.y), \(WorldLight.lampColor.z)) * 0.30;
                    // a presentation fill from the view's upper-left — the flank
                    // the marine sees is the gun's shadow side (rooms light from
                    // above), so every FPS keys its viewmodel or it silhouettes.
                    // It BREATHES with the room: scaled by the sector light at
                    // the gun, floored so the weapon never reads as pure black.
                    float plumG = dot(sectFill, float3(0.299, 0.587, 0.114));
                    float fillG = 0.10 + 0.55 * min(1.0, plumG);
                    float3 Lf = normalize(-0.45 * rN + 0.80 * float3(0.0, 1.0, 0.0) - 0.40 * U.fwd.xyz);
                    lit += (diffAlb * max(0.0, dot(n, Lf)) + specBP(n, V, Lf, rough, f0)) * float3(0.85, 0.90, 1.00) * fillG;
                    // warm pooled downlight from the nearby ceiling lamps (3×3, as the world)
                    {
                        int2 dim2 = int2(mapWH);
                        int lx0 = (int(floor(p.x)) / 2) * 2, lz0 = (int(floor(p.z)) / 2) * 2;
                        float3 pool = float3(0.0), poolSpec = float3(0.0);
                        for (int dz = -2; dz <= 2; dz += 2) {
                            for (int dx = -2; dx <= 2; dx += 2) {
                                int cx = lx0 + dx, cz = lz0 + dz;
                                if (cx < 0 || cz < 0 || cx >= dim2.x || cz >= dim2.y) continue;
                                if (wallId.read(uint2(uint(cx), uint(cz))).r != 0u) continue;
                                float3 tl = float3(float(cx) + 0.5, ceilH - 0.04, float(cz) + 0.5) - p;
                                float d2 = dot(tl, tl), dl = sqrt(d2);
                                float3 Ld = tl / dl;
                                float nl2 = max(0.0, dot(n, Ld));
                                float atn = 1.0 / (1.0 + d2 * 2.6);
                                float fdrop = fixtureFlicker(float2(float(cx), float(cz)), time);
                                pool += LAMP_WARM * ((1.9 * nl2 + 0.5) * atn * fdrop);
                                poolSpec += specBP(n, V, Ld, rough, f0) * LAMP_WARM * (atn * fdrop);
                            }
                        }
                        lit += (diffAlb * pool + poolSpec) * 0.42 * U.tune.x;   // overheads splash the gun; dims with the room (tune.x)
                    }
                    // dynamic + emitter lights — the muzzle flash and passing plasma
                    // bolts splash off the weapon's top surfaces
                    int nL2 = int(U.grid.w);
                    for (int li = 0; li < nL2; li++) {
                        float3 tl = lights[li].posR.xyz - p;
                        float d2 = dot(tl, tl);
                        float fA = 1.0 - d2 * lights[li].posR.w;
                        if (fA <= 0.0) continue;
                        float dl = sqrt(d2);
                        float3 Ld = tl / dl;
                        float nl2 = max(0.0, dot(n, Ld));
                        if (nl2 <= 0.0) continue;
                        float3 lcol = lights[li].colI.rgb * (lights[li].colI.w * fA * fA);
                        lit += (diffAlb * nl2 + specBP(n, V, Ld, rough, f0)) * lcol;
                    }
                    lit += alb * emv;                    // the energy core / pilot flame glow
                    col = lit;
                    volT = tv;                           // haze only between eye and weapon (≈ none)
                    vmDepth = tv * dot(rd, U.fwd.xyz);    // the gun's perp depth → owns these pixels
                }
            }
        }
        // volumetric fire — burning sources, integrated up to the nearest opaque
        // surface (volT) so walls/creatures/gun occlude it; additive HDR so it
        // blooms in the post pass. Gated on the count → zero cost out of combat.
        int nFire = int(U.tune.y);
        if (nFire > 0) {
            float bgT = 1.0;
            float3 fa = fireEmission(ro, rd, volT, ceilH, fires, nFire, time, bgT);
            col = col * bgT + fa;                // smoke darkens the scene; flame adds light
        }
        // volumetric in-scatter (haze + god-rays from the sector glow & lights)
        float jit = fract(sin(dot(float2(gid), float2(12.9898, 78.233))) * 43758.5453);
        col += volumetric(ro, rd, volT, dt, s, mapWH, lightTex, int(U.grid.w), lights, jit);
        outTex.write(float4(col, 1.0), gid);   // LINEAR HDR — the post pass tonemaps + blooms
        depthTex.write(float4(vmDepth > 0.0 ? vmDepth : (hit ? t * dot(rd, U.fwd.xyz) : 1e9), 0, 0, 0), gid);  // perp depth for sprite/mesh occlusion (gun wins where it drew)
    }

    // ── post: bloom (bright-pass gather) + exposure + ACES + gamma + vignette ──
    kernel void post(uint2 gid [[thread_position_in_grid]],
                     texture2d<float> hdr [[texture(0)]],
                     texture2d<float, access::write> ldr [[texture(1)]],
                     constant Uniforms& U [[buffer(0)]]) {
        float W = U.params.x, H = U.params.y;
        if (gid.x >= uint(W) || gid.y >= uint(H)) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        float2 texel = 1.0 / float2(W, H);
        float3 base = hdr.sample(s, uv).rgb;
        float3 bloom = float3(0.0);
        for (int i = 0; i < 24; i++) {                            // spiral gather of bright excess
            float ang = float(i) * 2.39996, rad = 1.0 + float(i) * 0.6;
            float3 c = hdr.sample(s, uv + float2(cos(ang), sin(ang)) * rad * texel * 2.0).rgb;
            float l = dot(c, float3(0.299, 0.587, 0.114));
            bloom += max(0.0, l - 1.35) / max(l, 0.001) * c;
        }
        float3 col = (base + bloom * (0.42 / 24.0)) * 0.58 * (1.0 - U.dbg.z);   // bloom add + exposure; dbg.z sags the whole scene (electrical-fault dim/flicker; 0 = normal)
        // teal/amber grade — lift the shadows cool, warm the highlights (the
        // colorimetric move that gives the beauty proof its filmic mood)
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(col * float3(0.84, 0.96, 1.16), col * float3(1.14, 1.0, 0.80), clamp(lum, 0.0, 1.0));
        col *= 1.05;
        col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);   // ACES
        col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));
        float2 d = uv * 2.0 - 1.0;
        col *= 1.0 - 0.34 * dot(d, d);                           // vignette
        // film grain: a subtle, animated luminance dither so the clean SDF surfaces
        // read grittier and less "plastic". Deliberately gentle (U.ro.w = time,
        // so the pattern shifts each frame). Monochrome = a filmic grain, not colour noise.
        float g = fract(sin(dot(float2(gid) + fract(U.ro.w) * 137.0, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        col = clamp(col + g * 0.10, 0.0, 1.0);
        ldr.write(float4(col, 1.0), gid);
    }
    """

    // ── Euclidean distance transform (Felzenszwalb & Huttenlocher, squared) ────
    private static func edt1d(_ f: inout [Float], _ n: Int, _ stride: Int, _ off: Int) {
        var d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Float](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0; z[0] = -.greatestFiniteMagnitude; z[1] = .greatestFiniteMagnitude
        @inline(__always) func fv(_ q: Int) -> Float { f[off + q * stride] }
        for q in 1..<n {
            var s = ((fv(q) + Float(q * q)) - (fv(v[k]) + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                s = ((fv(q) + Float(q * q)) - (fv(v[k]) + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
            }
            k += 1; v[k] = q; z[k] = s; z[k + 1] = .greatestFiniteMagnitude
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            d[q] = dq * dq + fv(v[k])
        }
        for q in 0..<n { f[off + q * stride] = d[q] }
    }

    /// True when a door's jambs lie on the x-axis (walls at x±1) — so its panels
    /// part along x. Otherwise they part along z.
    private static func doorSlidesAlongX(_ map: GameMap, _ cx: Int, _ cy: Int) -> Bool {
        let lx = map.inBounds(cx - 1, cy) && map.wall[map.idx(cx - 1, cy)] != 0
        let rx = map.inBounds(cx + 1, cy) && map.wall[map.idx(cx + 1, cy)] != 0
        return lx && rx
    }

    /// Through-axis centre of the ELEVATOR door plane: offset toward the open
    /// (room) side, so the rest of the cell is the car interior. 0.5 when the
    /// open side can't be determined (degrades to an ordinary centred door).
    private static func elevatorPlane(_ map: GameMap, _ cx: Int, _ cy: Int, slideX: Bool) -> Float {
        let (nx, ny) = slideX ? (cx, cy - 1) : (cx - 1, cy)       // lower-side neighbour on the through axis
        let (px, py) = slideX ? (cx, cy + 1) : (cx + 1, cy)
        let lowOpen  = map.inBounds(nx, ny) && map.wall[map.idx(nx, ny)] == 0
        let highOpen = map.inBounds(px, py) && map.wall[map.idx(px, py)] == 0
        if lowOpen == highOpen { return 0.5 }
        return lowOpen ? 0.20 : 0.80
    }

    /// Pack the live doors for the kernel: (cellX, cellY, part 0…1,
    /// flags bit0 = slides-along-x · bit1 = elevator). The kernel uses this for
    /// leaf-anchored texture UVs, so each leaf's artwork rides its sliding panel.
    static func packDoors(_ map: GameMap) -> [SIMD4<Float>] {
        map.doors.map { (i, d) in
            let cx = i % map.w, cy = i / map.w
            let slideX = doorSlidesAlongX(map, cx, cy)
            let part = min(1, d.open / GameMap.passThreshold)
            let flags = (slideX ? 1 : 0) + ((i == map.exitCell || i == map.entryCell) ? 2 : 0)
            return SIMD4(Float(cx), Float(cy), part, Float(flags))
        }
    }

    /// Distance (world units) from every sub-cell texel to the nearest wall.
    /// Doors are sampled at sub-cell resolution as CENTRE-SPLIT sliding panels: the
    /// parted gap (empty) grows from the cell centre out to the jambs as `open` →
    /// passThreshold, so the door visibly slides apart in the march / AO / shadows /
    /// reflections — not a binary pop. (The caller rebuilds the field as it slides.)
    static func buildDistanceField(_ map: GameMap) -> (data: [Float], sw: Int, sh: Int) {
        let S = sub
        let sw = map.w * S, sh = map.h * S
        let big: Float = Float(sw * sw + sh * sh)
        let invS = 1 / Float(S)
        var f = [Float](repeating: 0, count: sw * sh)
        for j in 0..<sh {
            let cy = j / S, sj = j % S
            for i in 0..<sw {
                let cx = i / S, si = i % S
                let ci = map.idx(cx, cy)
                var solid = map.wall[ci] != 0
                if solid, let d = map.doors[ci] {
                    let part = min(1, d.open / GameMap.passThreshold)        // 0 closed … 1 fully parted
                    let slideX = doorSlidesAlongX(map, cx, cy)
                    let slideC = (slideX ? Float(si) : Float(sj)) * invS + invS * 0.5   // along the wall (slide axis)
                    let thruC  = (slideX ? Float(sj) : Float(si)) * invS + invS * 0.5   // through the doorway
                    // The door is a THIN sliding panel set in the doorway — independent
                    // of the wall, NOT a full-depth block of it (which read as the wall
                    // moving). Solid only near the doorway plane (thin in the through
                    // axis) and only outside the parted centre gap, so a slim panel
                    // centre-splits and slides into the jambs while the wall stays put.
                    // The ELEVATOR (the exit cell's door) offsets its plane to the
                    // ROOM-side face: the cell interior behind the leaves becomes the
                    // car — the marine steps through, stands clear of the plane, and
                    // the doors close in front of his face for the ride down.
                    let thruMid = (ci == map.exitCell || ci == map.entryCell)
                        ? elevatorPlane(map, cx, cy, slideX: slideX) : 0.5
                    solid = (abs(thruC - thruMid) < 0.14) && (abs(slideC - 0.5) >= 0.5 * part)
                }
                f[j * sw + i] = solid ? 0 : big
            }
        }
        for j in 0..<sh { edt1d(&f, sw, 1, j * sw) }       // rows
        for i in 0..<sw { edt1d(&f, sh, sw, i) }           // columns
        for k in 0..<f.count { f[k] = sqrt(f[k]) * invS }  // texel² → world distance
        // Two channels, interleaved rg: .r = wall distance · .g = pipe-routing enable,
        // bilinear-upsampled from the cell-res map.pipe so the kernel reads it FREE
        // alongside the distance (no extra texture fetch in the march). The smooth
        // upsample gives the pipe its ~1-cell dive into the wall at every terminus.
        let pipe = map.pipe.isEmpty ? [Float](repeating: 0, count: map.w * map.h) : map.pipe
        var data = [Float](repeating: 0, count: sw * sh * 2)
        for j in 0..<sh {
            let fy = (Float(j) + 0.5) * invS - 0.5
            let y0 = max(0, min(map.h - 1, Int(floorf(fy)))), y1 = max(0, min(map.h - 1, y0 + 1))
            let ty = max(0, min(1, fy - Float(y0)))
            for i in 0..<sw {
                let fx = (Float(i) + 0.5) * invS - 0.5
                let x0 = max(0, min(map.w - 1, Int(floorf(fx)))), x1 = max(0, min(map.w - 1, x0 + 1))
                let tx: Float = max(0, min(1, fx - Float(x0)))
                let a: Float = pipe[y0 * map.w + x0]
                let b: Float = pipe[y0 * map.w + x1]
                let c: Float = pipe[y1 * map.w + x0]
                let e: Float = pipe[y1 * map.w + x1]
                let p0: Float = a + (b - a) * tx
                let p1: Float = c + (e - c) * tx
                let k = j * sw + i
                data[2 * k] = f[k]
                data[2 * k + 1] = p0 + (p1 - p0) * ty
            }
        }
        return (data, sw, sh)
    }

    struct Uniforms { var ro, fwd, right, up, params, grid, extra: SIMD4<Float>
                      var env: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // extra.x = decalCount · env.xy = water-table offset · env.zw = viewmodel shape start/count
                      var vmA: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // viewmodel: gun anchor.xyz + local bound radius
                      var vmB: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // viewmodel: gun-local bound centre
                      var dbg: SIMD4<Float> = SIMD4(0, 0, 0, 0)     // dbg.x = 1 → disable the per-ray creature mask (harness invariant checks)
                      var tune: SIMD4<Float> = SIMD4(1, 0, 0, 0) }  // tune.x = overhead-lamp brightness gain (1 = as-authored) · tune.y = fire-emitter count (0 ⇒ fire buffer never read)
    struct GPULight { var posR, colI: SIMD4<Float> }   // posR=(x,y,z,1/r²)  colI=(r,g,b,intensity)
    struct FireEmitter { var p0, p1, p2: SIMD4<Float> }   // p0=base.xyz+baseR · p1=flowDir.xyz(unit)+length · p2=intensity,seed,kind,spare
    struct GShape { var a, b, col: SIMD4<Float>; var bnd: SIMD4<Float> = .zero }   // a.xyz/r1 ; b.xyz/r2(<0 sphere) ; col.rgb/k ; bnd = enclosing sphere
    struct GMonster { var a, b, c: SIMD4<Float> }      // a=(x,z,yaw,scale) b=(start,count,boundR,boundCY) c=(minY,…)

    /// Fill each shape's enclosing sphere (bnd = centre.xyz + radius) from its
    /// primitive params. The kernel uses it as a cheap LOWER bound on the true
    /// distance so the smin loop can skip shapes that provably can't move the
    /// blend — MUST run on every shape list before it becomes a GPU buffer, or
    /// a zero bnd makes the kernel skip everything (invisible geometry).
    static func fillShapeBounds(_ shapes: inout [GShape]) {
        for i in shapes.indices {
            let sh = shapes[i]
            if sh.b.w < -2.5 {            // flat-capped cylinder: radius a.w, half-height b.y
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, simd_length(SIMD2(sh.a.w, sh.b.y)))
            } else if sh.b.w < -1.5 {     // rounded box: half-extents b.xyz + rounding a.w
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, simd_length(SIMD3(sh.b.x, sh.b.y, sh.b.z)) + sh.a.w)
            } else if sh.b.w < 0 {        // sphere
                shapes[i].bnd = SIMD4(sh.a.x, sh.a.y, sh.a.z, sh.a.w)
            } else {                      // round cone: hull of sphere(a, r1) ∪ sphere(b, r2)
                let av = SIMD3(sh.a.x, sh.a.y, sh.a.z), bv = SIMD3(sh.b.x, sh.b.y, sh.b.z)
                let c = (av + bv) * 0.5
                shapes[i].bnd = SIMD4(c.x, c.y, c.z, simd_length(bv - av) * 0.5 + max(sh.a.w, sh.b.w))
            }
        }
    }

    /// Replace each monster's yaw (a.z) with cos(-yaw) and stash sin(-yaw) in
    /// the spare c.w — the kernel's local-space transform runs per STEP per
    /// PIXEL, so the two transcendentals are hoisted to once per frame here.
    /// Destructive (a.z stops being an angle): run ONCE per packed list, right
    /// before the list becomes a GPU buffer, wherever fillShapeBounds runs.
    static func fillMonsterTrig(_ mons: inout [GMonster]) {
        for i in mons.indices {
            let yaw = mons[i].a.z
            mons[i].a.z = cosf(-yaw)
            mons[i].c.w = sinf(-yaw)
        }
    }

    /// Restructure monster shape lists for the GPU: per monster, prepend GROUP
    /// entries — one enclosing sphere (bnd) per run of 8 consecutive shapes,
    /// col.w = the run's max smin k — then the shapes themselves. The kernel
    /// tests a group once and skips all 8 members wholesale; skipping is the
    /// same EXACT smin no-op as the per-shape test (each member's lower bound
    /// ≥ the group's). Shapes are authored body-part by body-part, so
    /// consecutive runs are spatially tight — a 90-shape drone collapses to
    /// ~12 group tests per step for rays not grazing that body part.
    /// Layout per monster: [ceil(N/8) groups][N shapes]; b.x → group start,
    /// b.y stays N. Also fills shape bounds and hoists monster trig, so this
    /// REPLACES fillShapeBounds/fillMonsterTrig at monster-buffer sites.
    /// Run it BEFORE appending non-monster shapes (the viewmodel overlay):
    /// the rebuild keeps only monster-owned ranges.
    static func packShapeGroups(_ mons: inout [GMonster], _ shapes: inout [GShape]) {
        fillShapeBounds(&shapes)
        fillMonsterTrig(&mons)
        var out: [GShape] = []
        out.reserveCapacity(shapes.count + shapes.count / 8 + mons.count)
        for i in mons.indices {
            let start = Int(mons[i].b.x), n = Int(mons[i].b.y)
            mons[i].b.x = Float(out.count)
            guard n > 0 else { continue }
            for g in 0..<((n + 7) / 8) {
                let lo = start + g * 8, hi = min(lo + 8, start + n)
                var c = SIMD3<Float>.zero
                for si in lo..<hi { c += SIMD3(shapes[si].bnd.x, shapes[si].bnd.y, shapes[si].bnd.z) }
                c /= Float(hi - lo)
                var r: Float = 0, kmax: Float = 0
                for si in lo..<hi {
                    let b = shapes[si].bnd
                    r = max(r, simd_length(SIMD3(b.x, b.y, b.z) - c) + b.w)
                    kmax = max(kmax, shapes[si].col.w)
                }
                out.append(GShape(a: .zero, b: .zero, col: SIMD4(0, 0, 0, kmax), bnd: SIMD4(c.x, c.y, c.z, r)))
            }
            out.append(contentsOf: shapes[start..<(start + n)])
        }
        shapes = out
    }


    // ── item pickups as SDF objects (same kernel field as creatures) ──────────
    // GShape encodings: b.w = -1 sphere(r=a.w) · b.w = -2 rounded box(half=b.xyz, round=a.w) · b.w ≥ 0 round-cone.
    static func iBox(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ round: Float, _ col: SIMD3<Float>, _ k: Float = 0.008) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, round), b: SIMD4(h.x, h.y, h.z, -2), col: SIMD4(col.x, col.y, col.z, k))
    }
    static func iSphere(_ c: SIMD3<Float>, _ r: Float, _ col: SIMD3<Float>, _ k: Float = 0.008) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(0, 0, 0, -1), col: SIMD4(col.x, col.y, col.z, k))
    }
    static func iCone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float, _ col: SIMD3<Float>, _ k: Float = 0.02) -> GShape {
        GShape(a: SIMD4(a.x, a.y, a.z, r1), b: SIMD4(b.x, b.y, b.z, r2), col: SIMD4(col.x, col.y, col.z, k))
    }
    /// A flat-capped VERTICAL cylinder (Y axis) — the only primitive with genuinely
    /// FLAT top and bottom (boxes are square, cones/spheres dome at the ends). This
    /// is what an oil drum needs. Encoded with the sentinel b.w = -3: centre a.xyz,
    /// radius a.w, half-height b.y, edge-round b.x.
    static func iCylinder(_ c: SIMD3<Float>, r: Float, halfH: Float, round: Float, _ col: SIMD3<Float>, _ k: Float = 0.01) -> GShape {
        GShape(a: SIMD4(c.x, c.y, c.z, r), b: SIMD4(round, halfH, 0, -3), col: SIMD4(col.x, col.y, col.z, k))
    }

    /// Procedural 3-D design for each pickup (local space, feet ≈ y0). Each kind
    /// is built from a few crisply-coloured parts (low smin `k` on the detail so
    /// the cross / bands / stripe stay sharp, not melted) — a recognisable object,
    /// not a tinted blob. Shaded by the kernel's dedicated pickup path (controlled
    /// key+rim, held below the bloom threshold) so the form reads.
    static func itemShapes(_ kind: ItemKind) -> [GShape] {
        let white = SIMD3<Float>(0.90, 0.91, 0.95), red = SIMD3<Float>(0.86, 0.12, 0.10)
        let green = SIMD3<Float>(0.20, 0.72, 0.34), blue = SIMD3<Float>(0.30, 0.55, 0.97)
        let brass = SIMD3<Float>(0.82, 0.64, 0.20), darkM = SIMD3<Float>(0.14, 0.14, 0.17)
        let steel = SIMD3<Float>(0.40, 0.41, 0.46), olive = SIMD3<Float>(0.34, 0.39, 0.20)
        let cyan = SIMD3<Float>(0.40, 0.98, 1.15), yellow = SIMD3<Float>(0.95, 0.80, 0.16)
        let black = SIMD3<Float>(0.07, 0.07, 0.08)
        let d: Float = 0.0025                                   // crisp boundary for surface detail
        switch kind {
        case .stim:                                            // slim auto-injector: white barrel + GREEN chem charge & cross — a quick shot, deliberately NOT the red-cross case
            let barrel = white
            let chem = green
            return [iCylinder(SIMD3(0, 0.26, 0), r: 0.055, halfH: 0.15, round: 0.012, barrel, 0.004),   // glass barrel, upright
                    iCylinder(SIMD3(0, 0.20, 0), r: 0.059, halfH: 0.07, round: 0.004, chem, d),          // the charge — green fluid (protrudes a hair)
                    iCylinder(SIMD3(0, 0.435, 0), r: 0.085, halfH: 0.014, round: 0.006, steel, 0.004),   // plunger flange (thumb rest)
                    iBox(SIMD3(0, 0.475, 0), SIMD3(0.022, 0.03, 0.022), 0.008, steel, 0.004),            // plunger rod
                    iCone(SIMD3(0, 0.11, 0), SIMD3(0, 0.0, 0), 0.028, 0.0, steel),                       // needle: hub → point, down to the floor
                    iBox(SIMD3(0, 0.34, 0.056), SIMD3(0.05, 0.011, 0.012), 0.003, chem, d),              // green cross bar (front, on the white)
                    iBox(SIMD3(0, 0.34, 0.056), SIMD3(0.011, 0.032, 0.012), 0.003, chem, d)]             // green cross upright (front)
        case .medkit:                                          // white briefcase + bold red cross on top & front (the big heal)
            let body = white
            let cross = red
            let bx: Float = 0.26, by: Float = 0.12, bz: Float = 0.15, cy: Float = 0.17
            return [iBox(SIMD3(0, cy, 0), SIMD3(bx, by, bz), 0.01, body, 0.004),                      // case (wide, flat — briefcase)
                    iBox(SIMD3(0, cy + by + 0.022, -bz * 0.62), SIMD3(0.085, 0.02, 0.018), 0.012, steel, 0.004),  // handle (back edge, clear of cross)
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.12, 0.022, 0.038), 0.004, cross, d),            // top cross bar — always read from above
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.038, 0.022, 0.10), 0.004, cross, d),            // top cross bar
                    iBox(SIMD3(0, cy, bz), SIMD3(0.11, 0.032, 0.022), 0.004, cross, d),                // front cross
                    iBox(SIMD3(0, cy, bz), SIMD3(0.032, 0.10, 0.022), 0.004, cross, d)]                // front cross
        case .armor, .megaArmor:                               // chest plate + shoulders + chevron
            let c = kind == .megaArmor ? blue : green
            return [iBox(SIMD3(0, 0.26, 0), SIMD3(0.21, 0.24, 0.10), 0.03, c, 0.006),                 // breastplate
                    iBox(SIMD3(-0.23, 0.36, 0), SIMD3(0.06, 0.09, 0.10), 0.03, c, 0.006),             // L pauldron
                    iBox(SIMD3( 0.23, 0.36, 0), SIMD3(0.06, 0.09, 0.10), 0.03, c, 0.006),             // R pauldron
                    iBox(SIMD3(0, 0.30, 0.105), SIMD3(0.055, 0.13, 0.02), 0.004, SIMD3(0.95, 0.96, 1.0), d),   // chevron front
                    iBox(SIMD3(0, 0.30, -0.105), SIMD3(0.055, 0.13, 0.02), 0.004, SIMD3(0.95, 0.96, 1.0), d)]  // chevron back
        case .mineCrate:                                       // explosives crate + proximity mine sat on the lid
            return [iBox(SIMD3(0, 0.16, 0), SIMD3(0.24, 0.15, 0.16), 0.01, olive, 0.005),             // crate body (crisp)
                    iBox(SIMD3(0, 0.31, 0), SIMD3(0.235, 0.025, 0.155), 0.004, darkM, d),             // lid seam (top)
                    iBox(SIMD3(0, 0.10, 0), SIMD3(0.245, 0.02, 0.165), 0.004, brass, d),              // brass band — rings all sides
                    iBox(SIMD3(0, 0.22, 0), SIMD3(0.245, 0.02, 0.165), 0.004, brass, d),              // brass band — rings all sides
                    iCone(SIMD3(0, 0.33, 0), SIMD3(0, 0.395, 0), 0.10, 0.10, steel),                  // mine puck on the lid
                    iSphere(SIMD3(0, 0.43, 0), 0.035, SIMD3<Float>(1.0, 0.18, 0.12))]                 // red trigger lamp (glows)
        case .ammoFuel:                                        // pressurised fuel drum: red cylinder + cap + hazard band
            let fuelRed = SIMD3<Float>(0.62, 0.16, 0.10)
            return [iCone(SIMD3(0, 0.05, 0), SIMD3(0, 0.40, 0), 0.13, 0.13, fuelRed),                 // drum body
                    iCone(SIMD3(0, 0.40, 0), SIMD3(0, 0.45, 0), 0.135, 0.135, darkM),                 // top rim
                    iCone(SIMD3(0.05, 0.45, 0), SIMD3(0.05, 0.52, 0), 0.04, 0.04, brass),             // spout cap
                    iBox(SIMD3(0, 0.24, 0), SIMD3(0.15, 0.03, 0.15), 0.004, yellow, d)]               // hazard band (wraps)
        case .ammoRockets:                                     // warhead + fins (radial — reads at any spin)
            return [iCone(SIMD3(0, 0.06, 0), SIMD3(0, 0.40, 0), 0.075, 0.075, olive),                 // body
                    iCone(SIMD3(0, 0.40, 0), SIMD3(0, 0.54, 0), 0.075, 0.0, red),                     // tip
                    iBox(SIMD3(0.075, 0.10, 0), SIMD3(0.03, 0.06, 0.012), 0.004, darkM, d),           // fin
                    iBox(SIMD3(-0.075, 0.10, 0), SIMD3(0.03, 0.06, 0.012), 0.004, darkM, d),          // fin
                    iBox(SIMD3(0, 0.10, 0.075), SIMD3(0.012, 0.06, 0.03), 0.004, darkM, d),           // fin
                    iBox(SIMD3(0, 0.10, -0.075), SIMD3(0.012, 0.06, 0.03), 0.004, darkM, d)]          // fin
        case .ammoCells:                                       // battery: dark casing + glowing cyan RING + terminal
            return [iBox(SIMD3(0, 0.20, 0), SIMD3(0.15, 0.21, 0.12), 0.015, darkM, 0.005),            // casing
                    iBox(SIMD3(0, 0.15, 0), SIMD3(0.175, 0.045, 0.145), 0.004, cyan, d),              // glowing ring — wraps, protrudes
                    iBox(SIMD3(0, 0.26, 0), SIMD3(0.175, 0.04, 0.145), 0.004, cyan, d),               // second ring
                    iBox(SIMD3(0, 0.41, 0), SIMD3(0.06, 0.025, 0.05), 0.01, steel, d)]                // terminal cap (top)
        case .weaponRocket:                                    // echoes the held launcher: olive tube, red safety band + warhead, red aim bead
            let len: Float = 0.40
            let launcher = SIMD3<Float>(0.20, 0.27, 0.15)      // olive drab, matching the viewmodel tube
            return [iCone(SIMD3(-len, 0.24, 0), SIMD3(len, 0.24, 0), 0.07, 0.07, launcher),           // main tube (olive drab)
                    iCone(SIMD3(len * 0.34, 0.24, 0), SIMD3(len * 0.48, 0.24, 0), 0.078, 0.078, red), // red safety band
                    iCone(SIMD3(len - 0.02, 0.24, 0), SIMD3(len + 0.07, 0.24, 0), 0.05, 0.0, red),    // red warhead peeking, pointed
                    iBox(SIMD3(-len * 0.2, 0.12, 0), SIMD3(0.045, 0.09, 0.045), 0.015, black, 0.005), // grip
                    iBox(SIMD3(0, 0.32, 0), SIMD3(0.04, 0.04, 0.03), 0.01, darkM, 0.005),             // sight rail
                    iSphere(SIMD3(0, 0.365, 0), 0.016, SIMD3<Float>(1.0, 0.20, 0.12))]                // red aim bead (glows, like the held one)
        case .keyRed, .keyBlue, .keyYellow:                    // flat keycard: card + mag stripe + chip
            let c = kind == .keyRed ? red : (kind == .keyBlue ? blue : yellow)
            return [iBox(SIMD3(0, 0.24, 0), SIMD3(0.14, 0.20, 0.02), 0.008, c, 0.004),                // card
                    iBox(SIMD3(0, 0.31, 0.022), SIMD3(0.14, 0.035, 0.006), 0.002, black, d),          // mag stripe (front)
                    iBox(SIMD3(0, 0.31, -0.022), SIMD3(0.14, 0.035, 0.006), 0.002, black, d),         // mag stripe (back)
                    iBox(SIMD3(-0.07, 0.16, 0.022), SIMD3(0.04, 0.03, 0.006), 0.002, brass, d),       // chip (front)
                    iBox(SIMD3(-0.07, 0.16, -0.022), SIMD3(0.04, 0.03, 0.006), 0.002, brass, d)]      // chip (back)
        }
    }

    private static func shapeYExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -2.5 { return (sh.a.y - sh.b.y, sh.a.y + sh.b.y) }                      // cylinder (half-height b.y)
        if sh.b.w < -1.5 { return (sh.a.y - sh.b.y - sh.a.w, sh.a.y + sh.b.y + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.y - sh.a.w, sh.a.y + sh.a.w) }                       // sphere
        return (min(sh.a.y - sh.a.w, sh.b.y - sh.b.w), max(sh.a.y + sh.a.w, sh.b.y + sh.b.w))
    }
    private static func shapeRadius(_ sh: GShape, _ cy: Float) -> Float {
        if sh.b.w < -2.5 {                          // cylinder: radius a.w (XZ), half-height b.y (Y)
            let horiz = (sh.a.x * sh.a.x + sh.a.z * sh.a.z).squareRoot() + sh.a.w
            let vert = abs(sh.a.y - cy) + sh.b.y
            return (horiz * horiz + vert * vert).squareRoot()
        }
        if sh.b.w < -1.5 {
            let dx = abs(sh.a.x) + sh.b.x + sh.a.w, dy = abs(sh.a.y - cy) + sh.b.y + sh.a.w, dz = abs(sh.a.z) + sh.b.z + sh.a.w
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        if sh.b.w < 0 { return simd_length(SIMD3(sh.a.x, sh.a.y - cy, sh.a.z)) + sh.a.w }
        return max(simd_length(SIMD3(sh.a.x, sh.a.y - cy, sh.a.z)) + sh.a.w,
                   simd_length(SIMD3(sh.b.x, sh.b.y - cy, sh.b.z)) + sh.b.w)
    }

    /// Pack pickups into the same GMonster/GShape buffers — scaled small, hovering
    /// (c.y), gently spinning (yaw), so they read as floating 3-D objects.
    static func packItems(_ items: [Item], time: Float) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for (idx, it) in items.enumerated() {
            let sl = itemShapes(it.kind)
            if sl.isEmpty { continue }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.04
            // One shared scale (authored item-units ≈ ½ a wall) so each pickup keeps
            // its designed proportions — renormalising every kind to a fixed height
            // stretched the flat crates and oversized everything.
            let scale: Float = 0.55
            let phase = Float(idx) * 1.7 + it.bob
            let floatH: Float = 0.18 + sin(time * 2 + phase) * 0.04   // gentle bob
            let yaw = time * 0.8 + phase                              // slow spin
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(it.pos.x, it.pos.y, yaw, scale),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, floatH, 1, 0)))   // c.z = 1 → pickup material (controlled shading)
        }
        return (mons, shapes)
    }

    // ── rubble debris at battle-damage sites (static SDF geometry) ─────────────
    /// A small pile of charred chunks, deterministic from a per-site seed so it's
    /// stable frame-to-frame. Authored feet-on-floor (y≈0) in the same local space
    /// the creature/item path uses — packed as a no-spin GMonster.
    static func debrisShapes(_ seed: UInt32) -> [GShape] {
        func h(_ n: UInt32) -> Float {
            var x = seed &* 747796405 &+ (n &+ 1) &* 2891336453
            x = (x ^ (x >> 16)) &* 2246822519
            x = x ^ (x >> 13)
            return Float(x & 0xFFFF) / 65535
        }
        let charred = SIMD3<Float>(0.10, 0.10, 0.12), rust = SIMD3<Float>(0.22, 0.13, 0.08)
        let pale = SIMD3<Float>(0.30, 0.29, 0.31)
        let chunks = 3 + Int(h(0) * 2.99)                          // 3–5 chunks
        var out: [GShape] = []
        for i in 0..<chunks {
            let k = UInt32(i) * 7
            let ang = h(k + 1) * 6.2832, rad = 0.04 + h(k + 2) * 0.24
            let sx = 0.045 + h(k + 3) * 0.085, sy = 0.03 + h(k + 4) * 0.06, sz = 0.045 + h(k + 5) * 0.085
            let cy = sy + h(k + 6) * 0.015                          // resting on the floor
            let pick = h(k + 9)
            let col = pick < 0.55 ? charred : (pick < 0.82 ? rust : pale)
            out.append(iBox(SIMD3(cos(ang) * rad, cy, sin(ang) * rad), SIMD3(sx, sy, sz), 0.012, col, 0.01))
        }
        return out
    }

    /// Pack rubble piles into the shared GMonster/GShape buffers (no bob, no spin).
    static func packDebris(_ piles: [(pos: SIMD2<Float>, seed: UInt32)], budget: Int = 240) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for d in piles {
            let sl = debrisShapes(d.seed)
            if sl.isEmpty || shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(d.pos.x, d.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 0, 0)))
        }
        return (mons, shapes)
    }

    // ── environmental props: furniture & fixtures (static SDF, material c.z = 3) ─
    // Authored feet-on-floor (y≈0) in a 1-unit-tall room (floor 0 → ceiling 1),
    // FRONT facing local +Z and the wall behind at local −Z, so MapGen orients
    // each piece by setting yaw = atan2(-inward.x, inward.z). Built from the same
    // iBox/iCone/iSphere parts as the pickups, but flagged opaque (c.z = 3) so the
    // kernel shades them as lit industrial steel — a powered terminal screen is
    // authored over-bright so it self-glows.
    static func furnitureShapes(_ kind: FurnitureKind) -> [GShape] {
        let steel = SIMD3<Float>(0.40, 0.42, 0.47), darkM = SIMD3<Float>(0.13, 0.13, 0.16)
        let d: Float = 0.0025
        switch kind {
        case .bunk:                                            // barracks bunk (platform bed) — pillow at the wall (−Z)
            let mat = SIMD3<Float>(0.34, 0.37, 0.32), blanket = SIMD3<Float>(0.36, 0.25, 0.17)
            let pillow = SIMD3<Float>(0.60, 0.58, 0.52)
            let hl: Float = 0.42, hw: Float = 0.20
            // Lean (5 shapes, no separate legs) — every shape is re-evaluated for any
            // ray inside the bunk's bounding sphere, so fewer parts = less GPU.
            return [iBox(SIMD3(0, 0.07, 0), SIMD3(hw + 0.02, 0.07, hl + 0.02), 0.012, steel, 0.006),        // platform base (sits on the deck)
                    iBox(SIMD3(0, 0.155, 0.02), SIMD3(hw, 0.04, hl - 0.02), 0.03, mat, 0.012),              // mattress
                    iBox(SIMD3(0, 0.175, 0.16), SIMD3(hw - 0.01, 0.03, hl - 0.22), 0.02, blanket, 0.012),   // blanket, foot half
                    iBox(SIMD3(0, 0.185, -hl + 0.11), SIMD3(hw - 0.03, 0.034, 0.085), 0.03, pillow, 0.01),  // pillow at the head
                    iBox(SIMD3(0, 0.22, -hl - 0.01), SIMD3(hw + 0.02, 0.14, 0.02), 0.01, steel, 0.005)]     // headboard against the wall
        case .desk:                                            // office desk + still-powered terminal facing the room
            // screen = ARC amber phosphor (title-screen ratio 240:196:96), authored
            // over-bright (lum ≈ 1.2, same as the old teal) so it self-glows.
            let top = SIMD3<Float>(0.37, 0.38, 0.41), screen = SIMD3<Float>(1.45, 1.18, 0.58)
            return [iBox(SIMD3(0, 0.30, 0), SIMD3(0.36, 0.018, 0.19), 0.008, top, 0.005),                  // desk top
                    iBox(SIMD3(0, 0.15, -0.15), SIMD3(0.34, 0.15, 0.018), 0.004, top * 0.8, 0.005),        // modesty panel (wall side)
                    iBox(SIMD3(-0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, d),            // front legs
                    iBox(SIMD3( 0.30, 0.15, 0.13), SIMD3(0.025, 0.15, 0.025), 0.004, steel, d),
                    iBox(SIMD3(0, 0.45, -0.05), SIMD3(0.155, 0.115, 0.045), 0.01, darkM, 0.005),           // monitor housing
                    iBox(SIMD3(0, 0.45, 0.0), SIMD3(0.125, 0.092, 0.012), 0.004, screen, d),               // glowing screen (faces +Z)
                    iBox(SIMD3(0, 0.315, 0.06), SIMD3(0.10, 0.012, 0.05), 0.004, darkM, d)]                // keyboard
        case .chair:                                           // office chair (back at −Z so it tucks into a desk)
            let c = SIMD3<Float>(0.19, 0.20, 0.23)
            return [iBox(SIMD3(0, 0.21, 0), SIMD3(0.115, 0.02, 0.115), 0.02, c, 0.008),                    // seat
                    iBox(SIMD3(0, 0.33, -0.10), SIMD3(0.115, 0.115, 0.018), 0.02, c, 0.008),               // backrest
                    iCone(SIMD3(0, 0.0, 0), SIMD3(0, 0.20, 0), 0.024, 0.03, darkM),                        // post
                    iBox(SIMD3(0, 0.02, 0), SIMD3(0.10, 0.014, 0.10), 0.01, darkM, d)]                     // base
        case .locker:                                          // tall, NARROW steel locker (was fridge-wide)
            // The old locker was as wide as it was tall and read as a fridge. A real
            // barracks locker is narrow and full-height, with a recessed door, a vent
            // grille near the top, a vertical latch and a base plinth.
            let body = SIMD3<Float>(0.28, 0.30, 0.35), door = SIMD3<Float>(0.34, 0.36, 0.41)
            let vent = SIMD3<Float>(0.13, 0.14, 0.17)
            let hw: Float = 0.115, hd: Float = 0.105
            return [iBox(SIMD3(0, 0.435, -0.01), SIMD3(hw, 0.435, hd), 0.012, body, 0.006),                 // carcass (full-height, slim)
                    iBox(SIMD3(0, 0.45, hd - 0.004), SIMD3(hw - 0.018, 0.40, 0.012), 0.006, door, 0.004),   // recessed door face, set proud
                    iBox(SIMD3(0, 0.70, hd + 0.006), SIMD3(0.062, 0.05, 0.006), 0.003, vent, d),            // vent grille near the top
                    iBox(SIMD3(0.084, 0.45, hd + 0.012), SIMD3(0.012, 0.065, 0.012), 0.004, darkM, d),      // vertical latch handle (right edge)
                    iBox(SIMD3(0, 0.045, 0), SIMD3(hw - 0.004, 0.045, hd - 0.004), 0.004, darkM, 0.004)]    // base plinth (stands it off the deck)
        case .wallPipe:
            return pipeRunShapes(length: 1)                    // length comes from the Prop at pack time
        case .camera:                                          // ARC surveillance cam — the classic bullet CCTV on an L-bracket
            // A light-steel barrel with an overhanging sun HOOD and a blue lens in a
            // black bezel, mounted high in a corner on a wall-plate → arm → post. The
            // status LED (LAST shape) is over-bright red so it self-glows via bloom, and
            // packProps BLINKS it per-frame — ARC is watching. +Z = the way it looks.
            let cam = SIMD3<Float>(0.60, 0.62, 0.66)           // light steel — a white-grey unit, stands out from the dark set-dressing
            let glass = SIMD3<Float>(0.12, 0.20, 0.42), ledOn = SIMD3<Float>(2.8, 0.08, 0.05)
            let y: Float = 0.85, dd: Float = 0.004, s: Float = 0.5   // y = mount height (near the ceiling); s scales the unit
            return [iBox(SIMD3(0, y, -0.105 * s), SIMD3(0.05 * s, 0.055 * s, 0.014 * s), 0.006, cam, dd),         // wall plate (flush, −Z)
                    iBox(SIMD3(0, y, -0.055 * s), SIMD3(0.02 * s, 0.02 * s, 0.05 * s), 0.006, cam, dd),           // short arm to the barrel
                    iCone(SIMD3(0, y + 0.02 * s, -0.02 * s), SIMD3(0, y - 0.055 * s, 0.135 * s), 0.05 * s, 0.044 * s, cam, 0.006),  // barrel — angled DOWN-forward to watch the room
                    iBox(SIMD3(0, y + 0.05 * s, 0.03 * s), SIMD3(0.058 * s, 0.011 * s, 0.135 * s), 0.008, cam, 0.006),   // flat sun hood on top (overhangs)
                    iSphere(SIMD3(0, y - 0.07 * s, 0.16 * s), 0.03 * s, glass, 0.005),                            // blue lens — at the barrel's low-forward end
                    iSphere(SIMD3(0.03 * s, y - 0.055 * s, 0.115 * s), 0.022 * s, ledOn, 0.003)]                  // red status LED — protruding, front-underside, seen from below (LAST — blinks)
        }
    }

    /// A CONTINUOUS pipe run for the wall-ceiling corner: parallel pipes + a thin
    /// conduit spanning `length` along local X, sat flush at the wall (local −Z) up
    /// near the ceiling, with brackets at intervals. Pipes carry something somewhere
    /// — so they run the length of the wall and tuck into the corner, never free-
    /// stand mid-room or stop dead at one cell (the beauty-shot read).
    static func pipeRunShapes(length: Float) -> [GShape] {
        let pipe = SIMD3<Float>(0.38, 0.40, 0.44), rusty = SIMD3<Float>(0.32, 0.25, 0.17)
        let darkM = SIMD3<Float>(0.12, 0.12, 0.15)
        let h = max(0.6, length) * 0.5                         // half-run
        let zw: Float = -0.40                                  // hard against the wall (cell centre is 0.5 off the wall face)
        // Kept deliberately LEAN (2 pipes + a couple of saddles): a pipe run's
        // bounding sphere is large, so every extra shape is evaluated for a big
        // fraction of the room's rays — the GPU cost lives here, not in the look.
        var out: [GShape] = [
            iCone(SIMD3(-h, 0.86, zw), SIMD3(h, 0.86, zw), 0.050, 0.050, pipe),            // main feed pipe
            iCone(SIMD3(-h, 0.74, zw + 0.05), SIMD3(h, 0.74, zw + 0.05), 0.036, 0.036, rusty)]   // return pipe, rustier, sits proud
        var x = -h + 0.5                                       // saddle brackets clamping the run to the wall
        while x <= h - 0.2 {
            out.append(iBox(SIMD3(x, 0.80, zw + 0.03), SIMD3(0.018, 0.16, 0.09), 0.005, darkM, 0.004))
            x += 2.4
        }
        return out
    }

    // ── fuel drums (material c.z = 4) — a weathered 200-litre industrial barrel ──
    // Authored standing on the floor (y 0 → ~0.46), front = local +Z. Deliberately
    // LEAN: just a body + a domed lid (2 shapes); the rolling hoop ribs, rust and
    // grime are painted in the kernel's drum branch (free), not modelled. A drum is
    // about chest height — the reference barrel — in red-oxide or a blue-grey steel.
    static func drumShapes(red: Bool) -> [GShape] {
        let body = red ? SIMD3<Float>(0.46, 0.17, 0.12) : SIMD3<Float>(0.20, 0.25, 0.31)   // red-oxide / blue-grey
        let rim = body * 0.7
        // a 200-litre steel barrel: a flat-capped cylinder standing FLAT on the deck
        // (centre 0.225, half-height 0.225 → base at y0, top at 0.45) + a rolled top
        // rim that sticks proud. Rolling hoops + rust are painted in the drum branch.
        return [iCylinder(SIMD3(0, 0.225, 0), r: 0.155, halfH: 0.225, round: 0.02, body, 0.012),  // body, flat top + flat base
                iCylinder(SIMD3(0, 0.452, 0), r: 0.168, halfH: 0.022, round: 0.012, rim, 0.012)]   // rolled top rim
    }

    // ── recharge socket (material c.z = 5) — a flush WALL PANEL, not a floor unit ──
    // Wall-mounted infrastructure: a recessed housing with a vertical capacity bar
    // (segments lit up to the remaining charge) and a plug-in port, at chest height.
    // Authored back-to-wall (−Z) with the readout facing +Z into the room; packSockets
    // mounts it on the wall via yaw + the flush-to-wall shift, at its authored height
    // (NOT floored). The lit segments are over-bright so the kernel self-glows them.
    static func socketShapes(chargeFrac: Float, depleted: Bool = false) -> [GShape] {
        let housing = SIMD3<Float>(0.17, 0.19, 0.23), face = SIMD3<Float>(0.07, 0.08, 0.10)
        let lit = SIMD3<Float>(0.40, 1.45, 1.70), off = SIMD3<Float>(0.10, 0.13, 0.15)
        // drained: every lamp on the panel turns RED until the reserve re-arms
        let redLit = SIMD3<Float>(3.30, 0.16, 0.10), redOff = SIMD3<Float>(0.34, 0.05, 0.04)   // over-bright so the drained indicator still self-glows: red carries low luminance, so it must be high to cross the emissive gate — keeps the panel lit rather than winking out (which read as a local "dim")
        let frac = max(0, min(1, chargeFrac))
        let cy: Float = 0.52                                                                   // chest height
        var out: [GShape] = [
            iBox(SIMD3(0, cy, 0.02), SIMD3(0.135, 0.17, 0.035), 0.012, housing, 0.006),        // recessed housing (shallow)
            iBox(SIMD3(0, cy, 0.05), SIMD3(0.115, 0.15, 0.012), 0.004, face, 0.003),           // dark inset faceplate
        ]
        let segs = 4                                                                            // capacity bar
        for k in 0..<segs {
            let f = (Float(k) + 0.5) / Float(segs)
            let col = depleted ? (k == 0 ? redLit : redOff) : (f <= frac ? lit : off)
            out.append(iBox(SIMD3(-0.055, cy - 0.10 + Float(k) * 0.067, 0.062), SIMD3(0.05, 0.026, 0.006), 0.002, col, 0.0015))
        }
        out.append(iBox(SIMD3(0.07, cy, 0.06), SIMD3(0.04, 0.05, 0.008), 0.006, face, 0.003))   // plug-in port recess
        out.append(iSphere(SIMD3(0.07, cy, 0.066), 0.02,
                           depleted ? SIMD3<Float>(0.85, 0.14, 0.10) : SIMD3<Float>(0.22, 0.50, 0.60)))  // port lamp
        return out
    }

    private static func shapeZExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -2.5 { return (sh.a.z - sh.a.w, sh.a.z + sh.a.w) }                      // cylinder (radius a.w)
        if sh.b.w < -1.5 { return (sh.a.z - sh.b.z - sh.a.w, sh.a.z + sh.b.z + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.z - sh.a.w, sh.a.z + sh.a.w) }                       // sphere
        return (min(sh.a.z - sh.a.w, sh.b.z - sh.b.w), max(sh.a.z + sh.a.w, sh.b.z + sh.b.w))
    }
    private static func shapeXExtent(_ sh: GShape) -> (lo: Float, hi: Float) {
        if sh.b.w < -2.5 { return (sh.a.x - sh.a.w, sh.a.x + sh.a.w) }                      // cylinder (radius a.w)
        if sh.b.w < -1.5 { return (sh.a.x - sh.b.x - sh.a.w, sh.a.x + sh.b.x + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.x - sh.a.w, sh.a.x + sh.a.w) }                       // sphere
        return (min(sh.a.x - sh.a.w, sh.b.x - sh.b.w), max(sh.a.x + sh.a.w, sh.b.x + sh.b.w))
    }
    /// A piece of furniture's floor footprint as half-extents (X = along the wall, Z =
    /// into the room), derived from its authored geometry — the SINGLE source for both
    /// the rendered shape and the solid-collision box, so they can never drift apart.
    static func furnitureFootprint(_ kind: FurnitureKind) -> (halfW: Float, halfD: Float) {
        let sl = furnitureShapes(kind)
        var minX: Float = 1e9, maxX: Float = -1e9, minZ: Float = 1e9, maxZ: Float = -1e9
        for sh in sl {
            let ex = shapeXExtent(sh), ez = shapeZExtent(sh)
            minX = min(minX, ex.lo); maxX = max(maxX, ex.hi)
            minZ = min(minZ, ez.lo); maxZ = max(maxZ, ez.hi)
        }
        return ((maxX - minX) * 0.5, (maxZ - minZ) * 0.5)
    }
    /// Shove a wall piece back so its rear face sits flush against the wall. Local −Z
    /// is the wall side; the cell centre is 0.5 off the wall face, so the back lands
    /// at −wallBack (just shy of −0.5 to avoid z-fighting). Derived from the authored
    /// geometry, so it never drifts from the model — no per-kind magic depth.
    private static func flushToWall(_ shapes: inout [GShape], wallBack: Float = 0.46) {
        var minZ: Float = 1e9
        for sh in shapes { minZ = min(minZ, shapeZExtent(sh).lo) }
        let dz = -wallBack - minZ
        for i in shapes.indices {
            shapes[i].a.z += dz
            if shapes[i].b.w >= 0 { shapes[i].b.z += dz }   // round-cone: second endpoint is a real position
        }
    }

    /// Pack furniture/fixtures into the shared GMonster/GShape buffers (no bob, no
    /// spin — they sit where MapGen placed them, oriented by yaw). Material c.z = 3.
    static func packProps(_ props: [Prop], time: Float = 0, budget: Int = 220) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for pr in props {
            var sl = pr.kind == .wallPipe ? pipeRunShapes(length: pr.length) : furnitureShapes(pr.kind)
            if sl.isEmpty || shapes.count + sl.count > budget { break }
            if pr.kind == .camera, let li = sl.indices.last {   // BLINK the status LED (last shape): a steady ~0.7 Hz recording pulse
                let on = time.truncatingRemainder(dividingBy: 1.4) < 0.7
                sl[li].col = on ? SIMD4(2.8, 0.08, 0.05, sl[li].col.w) : SIMD4(0.16, 0.03, 0.03, sl[li].col.w)
            }
            // Wall pieces sit flush to the wall (bunk/desk/locker stood ~⅓-cell proud
            // before — "approx 1m" off). A free-standing chair keeps its placement.
            if pr.againstWall && pr.kind != .wallPipe { flushToWall(&sl) }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            // Floor furniture sits feet-on-deck (loY → floor); WALL-MOUNTED pieces (a
            // pipe run, a CCTV camera) are authored at their true height up the wall, so
            // they must keep it (yOff 0) — flooring dragged the run into the bunks / the
            // camera down onto the deck.
            let yOff: Float = (pr.kind == .wallPipe || pr.kind == .camera) ? 0 : loY
            mons.append(GMonster(a: SIMD4(pr.pos.x, pr.pos.y, pr.yaw, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(yOff, 0, 3, 0)))   // c.z = 3 → opaque industrial prop
        }
        return (mons, shapes)
    }

    /// Pack fuel drums (material c.z = 4). Red/blue alternates by a stable hash of
    /// the drum's cell so a barrel keeps its colour frame-to-frame. Feet on the deck.
    static func packDrums(_ drums: [Drum], budget: Int = 96) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for d in drums {
            let key = Int(d.pos.x.rounded()) &* 73856093 ^ Int(d.pos.y.rounded()) &* 19349663
            let sl = drumShapes(red: (key & 1) == 0)
            if shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(d.pos.x, d.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 4, 0)))   // c.z = 4 → fuel drum
        }
        return (mons, shapes)
    }

    /// Pack recharge sockets (material c.z = 5). A charged socket's cell self-glows;
    /// a drained one is authored dark so the marine reads it as spent.
    static func packSockets(_ sockets: [Socket], budget: Int = 64) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for sk in sockets {
            var sl = socketShapes(chargeFrac: Float(sk.charge) / Float(max(1, sk.maxCharge)), depleted: sk.depleted)
            if shapes.count + sl.count > budget { break }
            flushToWall(&sl)                                   // mount the panel flush on the wall behind
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(sk.pos.x, sk.pos.y, sk.yaw, 1),   // yaw mounts it onto the wall
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(0, 0, 5, 0)))        // yOff 0 → keep its authored chest height (not floored)
        }
        return (mons, shapes)
    }

    // ── deployed proximity mine (material c.z = 6) — a low floor puck + a pulsing
    // red trigger LED, so you can spot a live mine in the dark (and not cross your own)
    static func mineShapes() -> [GShape] {
        let body = SIMD3<Float>(0.16, 0.17, 0.20), collar = SIMD3<Float>(0.10, 0.11, 0.13)
        // a small, LOW disc the marine steps over (≈0.23 across, ≈0.12 tall — in line
        // with the old sprite, not larger). No collision; aliens cross it to trigger it.
        return [iCylinder(SIMD3(0, 0.026, 0), r: 0.115, halfH: 0.026, round: 0.01, body, 0.01),    // low puck on the deck
                iCylinder(SIMD3(0, 0.060, 0), r: 0.06, halfH: 0.016, round: 0.008, collar, 0.01),  // collar
                iSphere(SIMD3(0, 0.090, 0), 0.024, SIMD3<Float>(1.6, 0.10, 0.08))]                  // bright red trigger LED
    }
    /// Pack deployed mines (material c.z = 6), feet on the deck.
    static func packMines(_ mines: [Mine], budget: Int = 48) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for mn in mines {
            let sl = mineShapes()
            if shapes.count + sl.count > budget { break }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl { let e = shapeYExtent(sh); loY = min(loY, e.lo); hiY = max(hiY, e.hi) }
            let boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl { boundR = max(boundR, shapeRadius(sh, boundCY)) }
            boundR += 0.05
            let start = shapes.count
            shapes.append(contentsOf: sl)
            mons.append(GMonster(a: SIMD4(mn.pos.x, mn.pos.y, 0, 1),
                                 b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                                 c: SIMD4(loY, 0, 6, 0)))   // c.z = 6 → deployed mine
        }
        return (mons, shapes)
    }

    // ── projectiles as in-kernel emissive orbs (material c.z = 2) ──────────────
    static func projColor(_ k: ProjectileKind) -> SIMD3<Float> {
        switch k {
        case .plasma:   return SIMD3(0.28, 0.72, 1.20)
        case .rocket:   return SIMD3(1.00, 0.52, 0.18)
        case .bolt:     return SIMD3(1.00, 0.80, 0.26)
        case .fireball: return SIMD3(1.00, 0.38, 0.12)
        case .bfgBall:  return SIMD3(0.40, 1.15, 0.38)
        }
    }
    static func projRadius(_ k: ProjectileKind) -> Float {
        switch k {
        case .bfgBall:  return 0.26
        case .fireball: return 0.17
        case .rocket:   return 0.15
        case .plasma:   return 0.12
        case .bolt:     return 0.11
        }
    }
    /// Pack projectiles as single emissive spheres at eye height, flagged c.z = 2
    /// so the kernel shades them as glowing orbs (paired with the dynamic light
    /// each already casts, so they glow AND light the room).
    static func packProjectiles(_ projs: [Projectile], eyeY: Float = 0.5, cap: Int = 24) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for pr in projs {
            if mons.count >= cap { break }
            let r = projRadius(pr.kind)
            let start = shapes.count
            let col = projColor(pr.kind)
            // a bolt in flight is a STREAK, not a dot: the head orb plus a
            // fading tail stretched over ~45 ms of its own motion. Without it
            // a fast bolt lives three frames as a barely-visible dot, and
            // close-range fire has no visual at all.
            let speed = simd_length(pr.vel)
            let len = min(0.8, speed * 0.045)
            let yaw = atan2(pr.vel.y, pr.vel.x) + .pi / 2            // local -z = direction of flight
            // geometry is centred on the streak's midpoint so the bounding
            // sphere hugs it: anchored at the head the bound was len+r wide
            // and every ray inside it paid the detail evaluation — with a
            // dozen bolts in flight that was real frame time.
            shapes.append(iSphere(SIMD3(0, 0, -len / 2), r, col, 0.01))
            if len > 0.05 {
                shapes.append(iCone(SIMD3(0, 0, -len / 2), SIMD3(0, 0, len / 2), r * 0.85, r * 0.25, col * 0.55, 0.02))
            }
            let dirU = speed > 0.001 ? pr.vel / speed : SIMD2<Float>(1, 0)
            let anchor = pr.pos - dirU * (len / 2)                   // head stays exactly at pr.pos
            mons.append(GMonster(a: SIMD4(anchor.x, anchor.y, yaw, 1),
                                 b: SIMD4(Float(start), Float(shapes.count - start), len / 2 + r + 0.05, 0),
                                 c: SIMD4(0, eyeY, 2, 0)))           // centred at eye height; c.z = 2 (orb)
        }
        return (mons, shapes)
    }

    /// Build the kernel light buffer: the emitter point lights culled to what can
    /// reach the camera, ordered shadow-casters-first (so `extra.z` can gate which
    /// few march a shadow), the muzzle/projectile lights appended, capped to the
    /// buffer budget. Returns the packed lights and how many lead lights shadow.
    static func packLights(_ emitters: [Lighting.PointLight], camera: SIMD2<Float>,
                           muzzle: [GPULight] = [], maxLights: Int = 16, maxShadow: Int = 3) -> (lights: [GPULight], shadowCount: Int) {
        func toGPU(_ l: Lighting.PointLight) -> GPULight {
            GPULight(posR: SIMD4(l.pos.x, l.pos.y, l.pos.z, 1 / (l.radius * l.radius)),
                     colI: SIMD4(l.color.x, l.color.y, l.color.z, l.intensity))
        }
        func d2(_ l: Lighting.PointLight) -> Float { simd_length_squared(SIMD2(l.pos.x, l.pos.z) - camera) }
        // only fixtures whose reach can touch the camera neighbourhood matter
        let near = emitters.filter { d2($0) < ($0.radius + 6) * ($0.radius + 6) }
        let keys  = near.filter { $0.shadow }.sorted { d2($0) < d2($1) }
        let fills = near.filter { !$0.shadow }.sorted { d2($0) < d2($1) }
        // shadowed keys first (capped), then the muzzle lights (also shadowed — they
        // are the player's own dramatic light), then the cheap unshadowed colour fills
        let shadowKeys = Array(keys.prefix(maxShadow))
        var ordered = shadowKeys.map(toGPU)
        ordered.append(contentsOf: muzzle)
        let shadowCount = ordered.count                        // keys + muzzle all shadow
        ordered.append(contentsOf: fills.map(toGPU))
        if ordered.count > maxLights { ordered = Array(ordered.prefix(maxLights)) }
        return (ordered, min(shadowCount, ordered.count))
    }

    /// Compile both compute pipelines (raymarch → HDR, post → LDR), shared by the live renderer.
    static func makePipelines(_ device: MTLDevice) -> (raymarch: MTLComputePipelineState, post: MTLComputePipelineState)? {
        guard let lib = try? device.makeLibrary(source: kernelSource, options: nil),
              let rm = lib.makeFunction(name: "raymarch"), let po = lib.makeFunction(name: "post"),
              let rmp = try? device.makeComputePipelineState(function: rm),
              let pop = try? device.makeComputePipelineState(function: po) else { return nil }
        return (rmp, pop)
    }

    /// The procedural texture set (with baked relief) as a sampled 2-D array —
    /// the GPU walls/flats look up their cell's material id and sample this.
    static func makeTextureArray(_ device: MTLDevice, _ texs: [Texture]) -> MTLTexture? {
        guard let first = texs.first else { return nil }
        let sz = first.size
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
        d.width = sz; d.height = sz; d.arrayLength = texs.count
        d.usage = .shaderRead; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        for (i, t) in texs.enumerated() {
            // The array assumes a uniform tile size (every Texture is `size` today).
            // A mismatched tile would make replace() read past its pixel buffer —
            // assert in dev, and skip the slice in release rather than read OOB.
            assert(t.size == sz && t.pixels.count >= sz * sz, "makeTextureArray: non-uniform tile (\(t.size) vs \(sz))")
            guard t.size == sz, t.pixels.count >= sz * sz else { continue }
            t.pixels.withUnsafeBytes {
                tex.replace(region: MTLRegionMake2D(0, 0, sz, sz), mipmapLevel: 0, slice: i,
                            withBytes: $0.baseAddress!, bytesPerRow: sz * 4, bytesPerImage: sz * sz * 4)
            }
        }
        return tex
    }

    /// Per-cell material-id grid (nearest-read in the kernel).
    static func makeIdTexture(_ device: MTLDevice, _ ids: [Int], _ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let u = ids.map { UInt16(clamping: $0) }
        u.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
        return tex
    }

    /// Camera at the mouth of the longest *narrow* corridor in the map, looking
    /// straight down its long axis — a dark receding hallway directly comparable
    /// to the BeautyProof corridor hero. (The player's spawn lands in a bright,
    /// wide open room, which is useless for judging the moody-corridor target
    /// look — that mismatch is why earlier GPU stills read as "a bright test room".)
    static func bestCorridorView(_ map: GameMap) -> (pos: SIMD2<Float>, dir: Float, depth: Int)? {
        @inline(__always) func open(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < map.w && y < map.h && map.wall[map.idx(x, y)] == 0
        }
        let dirs: [(dx: Int, dy: Int, ang: Float)] = [
            (1, 0, 0), (-1, 0, .pi), (0, 1, .pi / 2), (0, -1, -.pi / 2)]
        var best: (score: Float, pos: SIMD2<Float>, dir: Float, depth: Int)?
        for y in 0..<map.h {
            for x in 0..<map.w where open(x, y) {
                for d in dirs {
                    if open(x - d.dx, y - d.dy) { continue }        // camera sits at a closed end
                    var len = 0, cx = x, cy = y
                    while open(cx, cy) && len < 64 { cx += d.dx; cy += d.dy; len += 1 }
                    if len < 5 { continue }
                    let px = d.dy, py = d.dx                         // perpendicular axis
                    var width = 1, k = 1
                    while open(x + px * k, y + py * k) { width += 1; k += 1 }
                    k = 1
                    while open(x - px * k, y - py * k) { width += 1; k += 1 }
                    let score = Float(len) - Float(width) * 1.5      // long + narrow wins
                    if best == nil || score > best!.score {
                        best = (score, SIMD2(Float(x) + 0.5, Float(y) + 0.5), d.ang, len)
                    }
                }
            }
        }
        guard let b = best else { return nil }
        return (b.pos, b.dir, b.depth)
    }
}
