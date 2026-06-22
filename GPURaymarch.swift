// Citadel — GPU SDF raymarcher, STAGE 1 (CITADEL_GPU headless harness).
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

    struct Uniforms { float4 ro, fwd, right, up, params, grid, extra; };  // extra.x = decalCount
    struct GPULight { float4 posR; float4 colI; };   // posR=(x,y,z,1/r²)  colI=(r,g,b,intensity)
    struct GShape   { float4 a, b, col; };  // a.xyz,a.w=r1 ; b.xyz,b.w=r2(<0 → sphere) ; col.rgb,col.w=k
    struct GMonster { float4 a, b, c; };    // a=(x,z,yaw,scale) b=(shapeStart,shapeCount,boundR,boundCY) c=(minY,…)
    // params = (screenW, viewH, horizon, ceilH);  grid = (mapW, mapH, monsterCount, lightCount)

    constant float3 WARM = float3(1.0, 0.92, 0.78);

    static inline float wallDist(texture2d<float> dt, sampler s, float2 xz, float2 mapWH) {
        return dt.sample(s, xz / mapWH).r;
    }
    // walls/floor/ceiling only — cheap, used by AO + dynamic-light shadows
    static inline float gridSDF(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH) {
        return min(wallDist(dt, s, p.xz, mapWH), min(p.y, ceilH - p.y));
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
    static inline float4 creatureField(float3 p, int nMon, constant GMonster* mons, constant GShape* shapes, thread float& mat) {
        float best = 1e9; float3 bestCol = float3(0.5, 0.2, 0.18); mat = 0.0;
        for (int mi = 0; mi < nMon; mi++) {
            GMonster m = mons[mi];
            float yaw = m.a.z, scale = m.a.w;
            float2 d = p.xz - m.a.xy;
            float cs = cos(-yaw), sn = sin(-yaw);
            float3 lp = float3((d.x * cs - d.y * sn) / scale, (p.y - m.c.y) / scale + m.c.x, (d.x * sn + d.y * cs) / scale);
            float bd = length(lp - float3(0.0, m.b.w, 0.0)) - m.b.z;   // bounding sphere (local)
            if (bd > 0.25) { best = min(best, bd * scale); continue; }
            int start = int(m.b.x), count = int(m.b.y);
            float dd = 1e9; float3 col = float3(0.5, 0.2, 0.18);
            for (int si = start; si < start + count; si++) {
                GShape sh = shapes[si];
                float sd;
                if (sh.b.w < -1.5) {                              // rounded box (items)
                    float3 q = abs(lp - sh.a.xyz) - sh.b.xyz;
                    sd = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - sh.a.w;
                } else if (sh.b.w < 0.0) {                        // sphere
                    sd = length(lp - sh.a.xyz) - sh.a.w;
                } else {                                          // round cone
                    sd = sdRoundCone(lp, sh.a.xyz, sh.b.xyz, sh.a.w, sh.b.w);
                }
                float k = sh.col.w;
                if (dd > 1e8) { dd = sd; col = sh.col.rgb; }
                else {
                    float h = clamp(0.5 + 0.5 * (sd - dd) / k, 0.0, 1.0);
                    dd = mix(sd, dd, h) - k * h * (1.0 - h);
                    col = mix(sh.col.rgb, col, h);
                }
            }
            dd *= scale;
            if (dd < best) { best = dd; bestCol = col; mat = m.c.z; }   // c.z = material (1 = pickup)
        }
        return float4(bestCol, best);
    }
    static inline float4 creatureField(float3 p, int nMon, constant GMonster* mons, constant GShape* shapes) {
        float mat; return creatureField(p, nMon, mons, shapes, mat);   // march/normal: material discarded
    }
    // full field: grid + creatures — used by the primary march + normals
    static inline float sceneSDF(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH,
                                 int nMon, constant GMonster* mons, constant GShape* shapes) {
        float g = gridSDF(p, dt, s, mapWH, ceilH);
        if (nMon > 0) g = min(g, creatureField(p, nMon, mons, shapes).w);
        return g;
    }
    static inline float3 calcNormal(float3 p, texture2d<float> dt, sampler s, float2 mapWH, float ceilH,
                                    int nMon, constant GMonster* mons, constant GShape* shapes) {
        float2 e = float2(0.004, 0.0);
        float dx = sceneSDF(p + e.xyy, dt, s, mapWH, ceilH, nMon, mons, shapes) - sceneSDF(p - e.xyy, dt, s, mapWH, ceilH, nMon, mons, shapes);
        float dy = sceneSDF(p + e.yxy, dt, s, mapWH, ceilH, nMon, mons, shapes) - sceneSDF(p - e.yxy, dt, s, mapWH, ceilH, nMon, mons, shapes);
        float dz = sceneSDF(p + e.yyx, dt, s, mapWH, ceilH, nMon, mons, shapes) - sceneSDF(p - e.yyx, dt, s, mapWH, ceilH, nMon, mons, shapes);
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

    static inline float wallEmissive(uint id) {
        if (id == 4u)  return 0.85;
        if (id == 16u) return 1.05;
        if (id == 10u) return 0.60;
        if (id == 13u || id == 14u || id == 15u) return 0.45;
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
            float dens = 0.004 + 0.014 * clamp(1.4 - p.y, 0.0, 1.0);   // base + steam near the floor
            float3 g = lightTex.sample(s, p.xz / mapWH).rgb * 0.25;
            for (int li = 0; li < nL; li++) {
                float3 tl = lights[li].posR.xyz - p;
                float f = 1.0 - dot(tl, tl) * lights[li].posR.w;
                if (f > 0.0) g += lights[li].colI.rgb * (lights[li].colI.w * f * f);
            }
            acc += g * (dens * ds * trans);
            trans *= exp(-dens * ds);
            t += ds;
            if (trans < 0.03) break;
        }
        return acc * 0.5;
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
                         constant Uniforms& U [[buffer(0)]]) {
        float screenW = U.params.x, viewH = U.params.y, horizon = U.params.z, ceilH = U.params.w;
        if (gid.x >= uint(screenW) || gid.y >= uint(viewH)) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        constexpr sampler ts(filter::linear, address::repeat, coord::normalized);
        float2 mapWH = U.grid.xy;
        int nMon = int(U.grid.z);

        float cameraX = 2.0 * (float(gid.x) + 0.5) / screenW - 1.0;
        float vcomp = (horizon - (float(gid.y) + 0.5)) / viewH;
        float3 rd = normalize(U.fwd.xyz + U.right.xyz * cameraX + U.up.xyz * vcomp);
        float3 ro = U.ro.xyz;
        float time = U.ro.w;

        float t = 0.02; bool hit = false;
        for (int i = 0; i < 190; i++) {
            float3 p = ro + rd * t;
            float d = sceneSDF(p, dt, s, mapWH, ceilH, nMon, mons, shapes);
            if (d < 0.0015) { hit = true; break; }
            t += d * 0.85;
            if (t > 64.0) break;
        }

        float3 col;
        if (hit) {
            float3 p = ro + rd * t;
            float3 n = calcNormal(p, dt, s, mapWH, ceilH, nMon, mons, shapes);
            float gd = gridSDF(p, dt, s, mapWH, ceilH);
            float itemMat = 0.0;
            float4 cf = (nMon > 0) ? creatureField(p, nMon, mons, shapes, itemMat) : float4(0.0, 0.0, 0.0, 1e9);
            float3 alb; float emis = 0.0; bool reflective = false; bool isItem = false; bool isProj = false;
            if (cf.w < gd) {                                     // a creature / pickup / projectile surface
                alb = cf.rgb;
                isItem = itemMat > 0.5 && itemMat < 1.5;         // c.z = 1 → pickup
                isProj = itemMat > 1.5;                          // c.z = 2 → glowing projectile orb
            } else {
                float dW = wallDist(dt, s, p.xz, mapWH);
                float dF = p.y, dC = ceilH - p.y;
                int2 dim = int2(mapWH);
                if (dW <= dF && dW <= dC) {                      // wall — id of the SOLID cell
                    int2 c = clamp(int2(floor(p.xz - n.xz * 0.5)), int2(0), dim - 1);
                    uint id = wallId.read(uint2(c)).r;
                    float along = (abs(n.x) > abs(n.z)) ? p.z : p.x;
                    alb = wallArr.sample(ts, float2(along, 1.0 - p.y), id).rgb;
                    emis = wallEmissive(id);
                    // ── battle scarring ── only the EMBEDDED light (the bright
                    //   strip / screen) emits, fails and flickers — not the whole
                    //   bulkhead. Mask by texel brightness so the dark panel body
                    //   stays steady while just the fixture pulses or dies.
                    if (id == 4u || id == 10u) {
                        float strip = smoothstep(0.36, 0.54, dot(alb, float3(0.299, 0.587, 0.114)));
                        emis *= strip;                                          // panel body doesn't glow
                        if (fixtureBusted(c)) { emis = 0.0; alb = mix(alb, alb * 0.30, strip); }  // dead: only the strip burns out
                        else emis *= fixtureFlicker(float2(c), time);           // only the strip flickers
                    }
                    float low = clamp(1.0 - p.y * 1.3, 0.0, 1.0);
                    float scorch = smoothstep(0.42, 0.78, fbm2(float2(along * 1.3, p.y * 1.4))) * (0.45 + 0.55 * low);
                    alb *= 1.0 - 0.82 * scorch;                                // sooty patches, heavier low
                    float streak = smoothstep(0.5, 0.92, fbm2(float2(along * 5.3, p.y * 0.5 + 11.0))) * clamp(p.y, 0.0, 1.0);
                    alb = mix(alb, alb * float3(0.52, 0.47, 0.42), streak * 0.6);   // grime bleeding down
                    float blood = smoothstep(0.55, 0.82, fbm2(float2(along * 2.1 + 7.0, p.y * 1.9))) * clamp(1.3 - p.y * 2.2, 0.0, 1.0);
                    alb = mix(alb, float3(0.2, 0.03, 0.022), blood * 0.85);    // dried blood up the base
                } else if (dF <= dC) {                           // floor — wet, reflective
                    int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint id = floorId.read(uint2(c)).r;
                    alb = flatArr.sample(ts, p.xz, id).rgb;
                    emis = flatEmissive(id);
                    reflective = true;
                    if (id == 3u || id == 8u) {                  // nukage / blood — live rippling surface
                        float2 q = p.xz;
                        n = normalize(n + float3(cos(q.x * 7.3 + time * 1.7), 0.0,
                                                 cos(q.y * 6.1 - time * 2.0)) * 0.18);   // moving ripples
                        if (id == 3u) emis *= 0.7 + 0.6 * (0.5 + 0.5 * sin(q.x * 3.1 + q.y * 2.7 + time * 2.2));
                    } else if (id != 2u) {                       // dry floors take soot + blood (not the grates)
                        float fscorch = smoothstep(0.46, 0.82, fbm2(p.xz * 1.9 + 40.0));
                        alb *= 1.0 - 0.62 * fscorch;
                        float fblood = smoothstep(0.56, 0.84, fbm2(p.xz * 1.5 + 21.0));
                        alb = mix(alb, float3(0.17, 0.024, 0.02), fblood * 0.72);
                    }
                    // located damage — blood at exact kill sites, scorch under
                    // corpses that burned out (a runtime world-space decal channel,
                    // stamped by gameplay events rather than baked from the cell hash)
                    int nD = int(U.extra.x);
                    if (nD > 0 && id != 2u && id != 3u && id != 8u) {
                        float dn = 0.5 + 0.5 * fbm2(p.xz * 3.3 + 5.0);          // one irregular-edge sample, shared
                        for (int di = 0; di < nD; di++) {
                            float4 dc = decals[di];
                            float rr = length(p.xz - dc.xy) / max(dc.z, 0.05);
                            if (rr >= 1.0) continue;
                            float edge = 1.0 - smoothstep(0.15, 1.0, rr);
                            float fall = edge * (0.62 + 0.38 * dn);             // solid core, noise erodes the rim
                            if (dc.w >= 0.0) alb *= 1.0 - 0.93 * fall * dc.w;    // scorch → charred black
                            else { float b = clamp(fall * (-dc.w) * 1.1, 0.0, 1.0);   // blood → dark wet pool
                                   alb = mix(alb, float3(0.13, 0.014, 0.011), b); }
                        }
                    }
                } else {                                         // ceiling + recessed lamp housings
                    int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint id = ceilId.read(uint2(c)).r;
                    alb = flatArr.sample(ts, p.xz, id).rgb;
                    // a lamp sits in every other open ceiling cell (the cell over a
                    // ceiling point is always open), so lamps follow the layout
                    if (isLampCell(c)) {
                        float2 ctr = float2(c) + 0.5;
                        float m = max(abs(p.x - ctr.x), abs(p.z - ctr.y));   // 0..0.5
                        if (m < LAMP_HALF) {
                            float face = 1.0 - smoothstep(LAMP_HALF * 0.42, LAMP_HALF, m);   // long soft edge, not a hard square
                            alb = mix(float3(0.06, 0.06, 0.08), LAMP_WARM, face);   // dark housing → warm face
                            emis = 3.6 * face * fixtureFlicker(float2(c), time);
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
            // pickups: controlled shading so the OBJECT reads — a soft key defines
            // the form, a rim picks out the silhouette, room colour keeps it sat in
            // the scene, and the whole thing is held below the bloom threshold so a
            // white medkit stays a white briefcase instead of a glowing blob
            float3 room = clamp(lightTex.sample(s, p.xz / mapWH).rgb, 0.4, 1.0);
            float3 kd = normalize(float3(0.4, 0.85, 0.3));
            float key = 0.32 + 0.68 * max(0.0, dot(n, kd));        // strong directional key — defines facets
            float fill = 0.18 * max(0.0, dot(n, normalize(float3(-0.5, 0.2, -0.4))));  // soft back-fill, no black faces
            float rim = pow(1.0 - max(0.0, dot(n, -rd)), 3.0);
            float3 lit = alb * (key + fill) * room + alb * rim * 0.30;
            // selective self-glow: only the brightest pickup detail (energy cells,
            // keycards) pushes past 1 and blooms — the white medkit stays controlled
            float gl = max(0.0, max(alb.r, max(alb.g, alb.b)) - 0.92);
            lit += alb * gl * 2.2;
            col = lit * exp(-t * 0.032);
          } else {
            float3 sect = min(lightTex.sample(s, p.xz / mapWH).rgb, float3(1.0));  // baked sector light (clamped)
            float ao = calcAO(p, n, dt, s, mapWH, ceilH);
            // hemisphere-tinted ambient: cool on up-facing, warm bounce underneath
            float hemiUp = 0.5 + 0.5 * n.y;
            float3 ambTint = mix(float3(0.82, 0.90, 1.06), float3(1.08, 0.97, 0.82), hemiUp);
            float3 toL = ro + float3(0.0, 0.22, 0.0) - p;        // headlamp near the marine
            float dist = length(toL);
            float ndl = max(0.0, dot(n, toL / dist));
            float atten = 1.0 / (1.0 + dist * dist * 0.45);
            float3 lit = alb * (sect * ambTint * 0.46 * ao + WARM * (ndl * atten * 0.78));
            lit += alb * emis;                                   // emissive surfaces glow
            // warm pooled downlight from the nearest ceiling lamp (over an open
            // cell) — gives rooms their lit pools without baking per-lamp lights
            {
                // sum the nearby ceiling lamps (3×3 grid of lamp cells) so their
                // pools OVERLAP into smooth falloff instead of hard per-cell squares
                int2 dim2 = int2(mapWH);
                int lx0 = (int(floor(p.x)) / 2) * 2, lz0 = (int(floor(p.z)) / 2) * 2;   // even = lamp cells
                float3 pool = float3(0.0);
                for (int dz = -2; dz <= 2; dz += 2) {
                    for (int dx = -2; dx <= 2; dx += 2) {
                        int cx = lx0 + dx, cz = lz0 + dz;
                        if (cx < 0 || cz < 0 || cx >= dim2.x || cz >= dim2.y) continue;
                        if (wallId.read(uint2(uint(cx), uint(cz))).r != 0u) continue;   // lamp only over open cell
                        float3 tl = float3(float(cx) + 0.5, ceilH - 0.04, float(cz) + 0.5) - p;
                        float d2 = dot(tl, tl), dl = sqrt(d2);
                        float nl = max(0.0, dot(n, tl / dl));
                        float atn = 1.0 / (1.0 + d2 * 1.35);
                        // directional pool on floors + a soft omni term so walls near
                        // a lamp brighten and fall off with distance
                        pool += LAMP_WARM * ((1.9 * nl + 0.5) * atn * fixtureFlicker(float2(float(cx), float(cz)), time));
                    }
                }
                lit += alb * pool * ao;
            }
            // dynamic lights — muzzle flash + projectiles, lit + soft-shadowed
            int nL = int(U.grid.w);
            for (int li = 0; li < nL; li++) {
                float3 tl = lights[li].posR.xyz - p;
                float d2 = dot(tl, tl);
                float f = 1.0 - d2 * lights[li].posR.w;
                if (f <= 0.0) continue;
                float dl = sqrt(d2);
                float3 Ld = tl / dl;
                float nl = max(0.0, dot(n, Ld));
                if (nl <= 0.0) continue;
                float shd = softShadow(p + n * 0.02, Ld, dl - 0.05, 18.0, dt, s, mapWH, ceilH);
                if (shd <= 0.0) continue;
                lit += alb * lights[li].colI.rgb * (lights[li].colI.w * f * f * nl * shd);
            }
            // wet-floor reflection — one grid-only bounce, Fresnel-weighted
            if (reflective) {
                float3 R = reflect(rd, n);
                float3 rc = reflectShade(p + n * 0.02, R, dt, s, ts, mapWH, ceilH, lightTex,
                                         wallArr, flatArr, wallId, floorId, ceilId);
                float fres = mix(0.0, 0.16, pow(1.0 - max(0.0, dot(n, -rd)), 4.0));   // faint wet sheen, not a mirror
                lit = mix(lit, rc * 0.6, fres);
            }
            col = lit * exp(-t * 0.032);                         // aerial falloff into dread-dark
          }
        } else {
            col = float3(0.010, 0.012, 0.020);
        }
        // volumetric in-scatter (haze + god-rays from the sector glow & lights)
        float jit = fract(sin(dot(float2(gid), float2(12.9898, 78.233))) * 43758.5453);
        col += volumetric(ro, rd, hit ? t : 28.0, dt, s, mapWH, lightTex, int(U.grid.w), lights, jit);
        outTex.write(float4(col, 1.0), gid);   // LINEAR HDR — the post pass tonemaps + blooms
        depthTex.write(float4(hit ? t * dot(rd, U.fwd.xyz) : 1e9, 0, 0, 0), gid);  // perp depth for sprite occlusion
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
        float3 col = (base + bloom * (0.42 / 24.0)) * 0.92;      // bloom add + exposure
        // teal/amber grade — lift the shadows cool, warm the highlights (the
        // colorimetric move that gives the beauty proof its filmic mood)
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(col * float3(0.90, 0.975, 1.07), col * float3(1.09, 1.0, 0.88), clamp(lum, 0.0, 1.0));
        col *= 1.05;
        col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);   // ACES
        col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));
        float2 d = uv * 2.0 - 1.0;
        col *= 1.0 - 0.28 * dot(d, d);                           // vignette
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

    /// Distance (world units) from every sub-cell texel to the nearest wall.
    static func buildDistanceField(_ map: GameMap) -> (data: [Float], sw: Int, sh: Int) {
        let S = sub
        let sw = map.w * S, sh = map.h * S
        let big: Float = Float(sw * sw + sh * sh)
        var f = [Float](repeating: 0, count: sw * sh)
        for j in 0..<sh {
            let cy = j / S
            for i in 0..<sw {
                let cx = i / S
                let ci = map.idx(cx, cy)
                var solid = map.wall[ci] != 0
                if solid, let d = map.doors[ci], d.open >= GameMap.passThreshold { solid = false }  // open doors = empty
                f[j * sw + i] = solid ? 0 : big
            }
        }
        for j in 0..<sh { edt1d(&f, sw, 1, j * sw) }       // rows
        for i in 0..<sw { edt1d(&f, sh, sw, i) }           // columns
        let invS = 1 / Float(S)
        for k in 0..<f.count { f[k] = sqrt(f[k]) * invS }  // texel² → world distance
        return (f, sw, sh)
    }

    struct Uniforms { var ro, fwd, right, up, params, grid, extra: SIMD4<Float> }   // extra.x = decalCount
    struct GPULight { var posR, colI: SIMD4<Float> }   // posR=(x,y,z,1/r²)  colI=(r,g,b,intensity)
    struct GShape { var a, b, col: SIMD4<Float> }      // a.xyz/r1 ; b.xyz/r2(<0 sphere) ; col.rgb/k
    struct GMonster { var a, b, c: SIMD4<Float> }      // a=(x,z,yaw,scale) b=(start,count,boundR,boundCY) c=(minY,…)

    /// The creature's current pose as CreatureLab shapes, by gameplay state.
    static func poseShapes(_ m: Monster) -> [CreatureLab.Shape] {
        let cdef = MonsterBake.cdef(m.kind)
        switch m.state {
        case .dead:   return CreatureLab.deadShapes(cdef.build(0, 0), d: 1, gib: false, decals: false)
        case .dying:  return CreatureLab.deadShapes(cdef.build(0, 0), d: min(1, m.stateTime / 0.5), gib: false, decals: false)
        case .attack: return cdef.build(0.25, 1)
        default:      return cdef.build(m.animTime - floorf(m.animTime), 0)
        }
    }

    /// Pack visible monsters into GPU buffers: scale each creature to fit the
    /// room height (feet on the floor), bound it, and flatten its shapes.
    static func packCreatures(_ monsters: [Monster], shapeBudget: Int = 220) -> ([GMonster], [GShape]) {
        var mons: [GMonster] = [], shapes: [GShape] = []
        for m in monsters {
            let sl = poseShapes(m)
            if sl.isEmpty || shapes.count + sl.count > shapeBudget { continue }
            var loY: Float = 1e9, hiY: Float = -1e9
            for sh in sl {
                let r = max(sh.r1, sh.r2)
                loY = min(loY, min(sh.a.y, sh.b.y) - r)
                hiY = max(hiY, max(sh.a.y, sh.b.y) + r)
            }
            let bodyH = max(0.1, hiY - loY), boundCY = (loY + hiY) / 2
            var boundR: Float = 0
            for sh in sl {
                boundR = max(boundR, simd_length(SIMD3(sh.a.x, sh.a.y - boundCY, sh.a.z)) + sh.r1)
                boundR = max(boundR, simd_length(SIMD3(sh.b.x, sh.b.y - boundCY, sh.b.z)) + sh.r2)
            }
            boundR += 0.06
            // Reproduce the sprite's apparent size: the bake tile spanned viewH
            // creature-units and was billboarded billboardH walls tall, so one
            // creature-unit = billboardH/viewH walls. (Scaling the body straight
            // to ~0.92 of the wall ignored the sprite's transparent padding and
            // rendered creatures far larger than they ever looked.)
            let fit = m.def.billboardH / MonsterBake.cdef(m.kind).viewH
            // a burning corpse shrinks toward a charred husk (~⅓ size) and darkens —
            // it doesn't vanish; scorched remains stay on the floor
            let scale = min(fit, 0.92 / bodyH) * max(0.34, 1 - m.burn * 0.66)
            let darks = 1 - max(0, min(1, (m.burn - 0.3) / 0.7)) * 0.82      // → charred near-black
            let start = shapes.count
            for sh in sl {
                shapes.append(GShape(
                    a: SIMD4(sh.a.x, sh.a.y, sh.a.z, sh.r1),
                    b: SIMD4(sh.b.x, sh.b.y, sh.b.z, sh.sphere ? -1 : sh.r2),
                    col: SIMD4(sh.col.x / 255 * darks, sh.col.y / 255 * darks, sh.col.z / 255 * darks, sh.k)))
            }
            mons.append(GMonster(
                a: SIMD4(m.pos.x, m.pos.y, m.dir + .pi / 2, scale),
                b: SIMD4(Float(start), Float(sl.count), boundR, boundCY),
                c: SIMD4(loY, 0, 0, 0)))
        }
        return (mons, shapes)
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
        case .stim, .medkit:                                   // white briefcase + bold red cross on top & front
            let body = white
            let cross = red
            let s: Float = kind == .medkit ? 1.0 : 0.78
            let bx = 0.26 * s, by = 0.12 * s, bz = 0.15 * s, cy = 0.17 * s
            return [iBox(SIMD3(0, cy, 0), SIMD3(bx, by, bz), 0.01, body, 0.004),                      // case (wide, flat — briefcase)
                    iBox(SIMD3(0, cy + by + 0.022 * s, -bz * 0.62), SIMD3(0.085 * s, 0.02 * s, 0.018 * s), 0.012, steel, 0.004),  // handle (back edge, clear of cross)
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.12 * s, 0.022 * s, 0.038 * s), 0.004, cross, d),// top cross bar — always read from above
                    iBox(SIMD3(0, cy + by, 0), SIMD3(0.038 * s, 0.022 * s, 0.10 * s), 0.004, cross, d),// top cross bar
                    iBox(SIMD3(0, cy, bz), SIMD3(0.11 * s, 0.032 * s, 0.022 * s), 0.004, cross, d),    // front cross
                    iBox(SIMD3(0, cy, bz), SIMD3(0.032 * s, 0.10 * s, 0.022 * s), 0.004, cross, d)]    // front cross
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
        case .weaponRocket:                                    // launcher tube + grip + dark muzzle bore
            let len: Float = 0.40
            return [iCone(SIMD3(-len, 0.24, 0), SIMD3(len, 0.24, 0), 0.07, 0.07, steel),              // tube
                    iCone(SIMD3(len, 0.24, 0), SIMD3(len + 0.03, 0.24, 0), 0.073, 0.05, black),       // muzzle bore
                    iBox(SIMD3(-len * 0.2, 0.12, 0), SIMD3(0.045, 0.09, 0.045), 0.015, black, 0.005), // grip
                    iBox(SIMD3(0, 0.32, 0), SIMD3(0.04, 0.04, 0.03), 0.01, darkM, 0.005)]             // sight
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
        if sh.b.w < -1.5 { return (sh.a.y - sh.b.y - sh.a.w, sh.a.y + sh.b.y + sh.a.w) }   // box
        if sh.b.w < 0   { return (sh.a.y - sh.a.w, sh.a.y + sh.a.w) }                       // sphere
        return (min(sh.a.y - sh.a.w, sh.b.y - sh.b.w), max(sh.a.y + sh.a.w, sh.b.y + sh.b.w))
    }
    private static func shapeRadius(_ sh: GShape, _ cy: Float) -> Float {
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
            shapes.append(iSphere(SIMD3(0, 0, 0), r, projColor(pr.kind), 0.01))
            mons.append(GMonster(a: SIMD4(pr.pos.x, pr.pos.y, 0, 1),
                                 b: SIMD4(Float(start), 1, r + 0.05, 0),
                                 c: SIMD4(0, eyeY, 2, 0)))           // centred at eye height; c.z = 2 (orb)
        }
        return (mons, shapes)
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

    static func run(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice() else { print("Citadel: no Metal device"); return }
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-GPU")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let W = RenderConfig.width, H = RenderConfig.viewHeight
        let queue = device.makeCommandQueue()!
        guard let (pipe, post) = makePipelines(device) else { print("Citadel: kernel build failed"); return }
        let wallArr = makeTextureArray(device, Textures.shared.walls)
        let flatArr = makeTextureArray(device, Textures.shared.flats)

        // a few real levels, from the player's spawn
        for level in [1, 4, 7] {
            let world = World(level: level, colonyIndex: level - 1, seed: 1234 &+ UInt64(level))
            let map = world.map
            let (df, sw, sh) = buildDistanceField(map)

            // distance-field texture (R32Float)
            let dtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: sw, height: sh, mipmapped: false)
            dtDesc.usage = .shaderRead; dtDesc.storageMode = .shared
            let dtTex = device.makeTexture(descriptor: dtDesc)!
            df.withUnsafeBytes { dtTex.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: sw * 4) }

            // baked sector-light texture (RGBA32Float at grid res)
            var lc = [SIMD4<Float>](repeating: .zero, count: map.w * map.h)
            for k in 0..<lc.count { let c = map.lightColor[k]; lc[k] = SIMD4(c.x, c.y, c.z, 1) }
            let liDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: map.w, height: map.h, mipmapped: false)
            liDesc.usage = .shaderRead; liDesc.storageMode = .shared
            let liTex = device.makeTexture(descriptor: liDesc)!
            lc.withUnsafeBytes { liTex.replace(region: MTLRegionMake2D(0, 0, map.w, map.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: map.w * 16) }

            // HDR work texture (raymarch writes linear HDR) + LDR readback texture
            let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
            hdrDesc.usage = [.shaderWrite, .shaderRead]; hdrDesc.storageMode = .private
            let hdrTex = device.makeTexture(descriptor: hdrDesc)!
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
            outDesc.usage = [.shaderWrite, .shaderRead]; outDesc.storageMode = .shared
            let outTex = device.makeTexture(descriptor: outDesc)!
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
            depthDesc.usage = [.shaderWrite, .shaderRead]; depthDesc.storageMode = .private
            let depthTex = device.makeTexture(descriptor: depthDesc)!

            let wallIdT = makeIdTexture(device, map.wall, map.w, map.h)
            let floorIdT = makeIdTexture(device, map.floor, map.w, map.h)
            let ceilIdT = makeIdTexture(device, map.ceil, map.w, map.h)

            // camera = the live raycaster's basis, as a 3-D frame
            let p = world.player
            let dirX = cos(p.dir), dirY = sin(p.dir)
            let plane: Float = RenderConfig.cameraPlane
            var u = Uniforms(
                ro: SIMD4(p.pos.x, 0.5, p.pos.y, 2.3),   // .w = time; fixed phase so flicker/dead lamps show in the still
                fwd: SIMD4(dirX, 0, dirY, 0),
                right: SIMD4(-sin(p.dir) * plane, 0, cos(p.dir) * plane, 0),
                up: SIMD4(0, 1, 0, 0),
                params: SIMD4(Float(W), Float(H), Float(RenderConfig.horizon), 1.0),
                grid: SIMD4(Float(map.w), Float(map.h), world.elapsed, 0),
                extra: SIMD4(0, 0, 0, 0))

            // a test dynamic light ahead/to one side of the camera, so the
            // headless render exercises the muzzle/projectile lighting + shadow path
            let fwd2 = SIMD2<Float>(dirX, dirY), side = SIMD2<Float>(-dirY, dirX)
            let lpos = p.pos + fwd2 * 2.4 + side * 0.7
            let radT: Float = 6.0
            var dyn = [GPULight(posR: SIMD4(lpos.x, 0.55, lpos.y, 1 / (radT * radT)),
                                colI: SIMD4(1.0, 0.8, 0.5, 2.4))]
            u.grid.w = 1

            // a test creature ahead, facing the camera, to verify the native SDF
            // path — one dying (verifies the pool fix) and one alive
            var tm = Monster(kind: .queen, pos: p.pos + fwd2 * 4.4 - side * 2.1)
            tm.dir = p.dir + .pi; tm.state = .dying; tm.stateTime = 0.45
            var tm2 = Monster(kind: .alien, pos: p.pos + fwd2 * 4.4 + side * 2.1)
            tm2.dir = p.dir + .pi
            var (cmons, cshapes) = packCreatures([tm, tm2])
            // test pickups — a representative spread, well separated, to verify
            // each SDF form reads (medkit / ammo crate / energy cell / keycard)
            let ti = [Item(kind: .medkit, pos: p.pos + fwd2 * 1.7 - side * 0.95),
                      Item(kind: .mineCrate, pos: p.pos + fwd2 * 1.7 - side * 0.32),
                      Item(kind: .ammoCells, pos: p.pos + fwd2 * 1.7 + side * 0.32),
                      Item(kind: .keyBlue, pos: p.pos + fwd2 * 1.7 + side * 0.95)]
            let (imons, ishapes) = packItems(ti, time: 0.6)
            let ibase = cshapes.count
            for im0 in imons { var im = im0; im.b.x += Float(ibase); cmons.append(im) }
            cshapes.append(contentsOf: ishapes)
            // a rubble pile to prove the static-debris path
            let (dmons, dshapes) = packDebris([(p.pos + fwd2 * 2.6, 0x9E37_79B1)])
            let dbase = cshapes.count
            for dm0 in dmons { var dm = dm0; dm.b.x += Float(dbase); cmons.append(dm) }
            cshapes.append(contentsOf: dshapes)
            // glowing projectile orbs (plasma + fireball) to prove the in-kernel path
            let tp = [Projectile(pos: p.pos + fwd2 * 3.0 + side * 1.3, vel: .zero, kind: .plasma, damage: 0, fromPlayer: true, life: 1),
                      Projectile(pos: p.pos + fwd2 * 3.0 - side * 1.3, vel: .zero, kind: .fireball, damage: 0, fromPlayer: false, life: 1)]
            let (ppmons, ppshapes) = packProjectiles(tp)
            let ppbase = cshapes.count
            for pm0 in ppmons { var pm = pm0; pm.b.x += Float(ppbase); cmons.append(pm) }
            cshapes.append(contentsOf: ppshapes)
            u.grid.z = Float(cmons.count)
            // located decals: a blood pool and a scorch mark on the floor ahead
            var decals: [SIMD4<Float>] = [
                SIMD4(p.pos.x + fwd2.x * 2.0, p.pos.y + fwd2.y * 2.0, 0.85, -0.9),                      // blood
                SIMD4(p.pos.x + fwd2.x * 2.6, p.pos.y + fwd2.y * 2.6, 1.0, 0.95)]                       // scorch under the rubble
            u.extra.x = Float(decals.count)
            if decals.isEmpty { decals = [SIMD4(0, 0, 0, 0)] }
            if cmons.isEmpty { cmons = [GMonster(a: .zero, b: .zero, c: .zero)] }
            if cshapes.isEmpty { cshapes = [GShape(a: .zero, b: .zero, col: .zero)] }
            let monBuf = device.makeBuffer(bytes: cmons, length: MemoryLayout<GMonster>.stride * cmons.count, options: .storageModeShared)
            let shpBuf = device.makeBuffer(bytes: cshapes, length: MemoryLayout<GShape>.stride * cshapes.count, options: .storageModeShared)

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipe)
            enc.setTexture(dtTex, index: 0)
            enc.setTexture(liTex, index: 1)
            enc.setTexture(hdrTex, index: 2)
            enc.setTexture(wallArr, index: 3)
            enc.setTexture(flatArr, index: 4)
            enc.setTexture(wallIdT, index: 5)
            enc.setTexture(floorIdT, index: 6)
            enc.setTexture(ceilIdT, index: 7)
            enc.setTexture(depthTex, index: 8)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setBytes(&dyn, length: MemoryLayout<GPULight>.stride * dyn.count, index: 1)
            enc.setBuffer(monBuf, offset: 0, index: 2)
            enc.setBuffer(shpBuf, offset: 0, index: 3)
            enc.setBytes(&decals, length: MemoryLayout<SIMD4<Float>>.stride * decals.count, index: 4)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
            let penc = cmd.makeComputeCommandEncoder()!
            penc.setComputePipelineState(post)
            penc.setTexture(hdrTex, index: 0)
            penc.setTexture(outTex, index: 1)
            penc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            penc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            penc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: W * H)
            outTex.getBytes(buf, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            Captures.writePNG(buf, w: W, h: H, scale: 1, to: dir.appendingPathComponent(String(format: "gpu-stage1-depth%d.png", level)))
            buf.deallocate()
            print("  wrote gpu-stage1-depth\(level).png  (grid \(map.w)×\(map.h), DT \(sw)×\(sh))")
        }
        print("Citadel: GPU Stage-1 renders written to \(dir.path)")
    }
}
