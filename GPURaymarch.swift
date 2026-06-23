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

    // ── PBR material params + micro-relief (the "walls & materials" model) ──────
    // Per-surface roughness/metalness, mirroring BeautyProof's material(): grimy
    // iron is a dirty half-metal, brushed steel / pipes are cleaner metal, glass
    // is a smooth dielectric, stone & concrete are matte. (x = rough, y = metal.)
    static inline float2 wallMaterial(uint id) {
        switch (id) {
            case 2u:  return float2(0.36, 0.70);   // brushed steel — the good rooms
            case 5u:  return float2(0.34, 0.65);   // ribbed conduit metal
            case 6u:  return float2(0.28, 0.80);   // pipework — smooth metal
            case 7u:  return float2(0.18, 0.25);   // reinforced glass — smooth dielectric
            case 8u:  return float2(0.92, 0.00);   // hewn rock — matte
            case 9u:  return float2(0.66, 0.35);   // rock + steel struts
            case 10u: return float2(0.50, 0.20);   // computer banks — screens
            case 12u: case 13u: case 14u: case 15u: return float2(0.50, 0.50);  // blast doors — painted steel
            case 16u: return float2(0.50, 0.45);   // exit switch panel
            default:  return float2(0.58, 0.50);   // iron plate / steel panel / lit panel / hazard — grimy iron
        }
    }
    // floor + ceiling flats: metal deck / grate are metal, concrete / stone matte.
    static inline float2 flatMaterial(uint id) {
        switch (id) {
            case 1u: return float2(0.44, 0.65);    // metal deck plate
            case 2u: return float2(0.55, 0.55);    // walkway grate
            case 4u: return float2(0.55, 0.25);    // ceiling tech
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
            if (isLampCell(c)) {                              // the wet floor must mirror the bright lamps
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
            float3 alb; float emis = 0.0; bool reflective = false; bool isItem = false; bool isProj = false; bool isCreature = false;
            float rough = 0.7, metal = 0.0;   // PBR surface params, set per surface below
            if (cf.w < gd) {                                     // a creature / pickup / projectile surface
                alb = cf.rgb;
                isItem = itemMat > 0.5 && itemMat < 1.5;         // c.z = 1 → pickup
                isProj = itemMat > 1.5;                          // c.z = 2 → glowing projectile orb
                isCreature = !isItem && !isProj;                 // c.z = 0 → living flesh
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
                    // material + micro-relief — a grimy-iron sheen, with grain
                    // breaking up the highlight (was flat, matte, light-frozen)
                    float2 wm = wallMaterial(id); rough = wm.x; metal = wm.y;
                    float3 tU = (abs(n.x) > abs(n.z)) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
                    n = bumpNormal(float2(along, p.y), n, tU, float3(0.0, 1.0, 0.0), 2.6, 0.16 * smoothstep(0.15, 0.55, rough));
                } else if (dF <= dC) {                           // floor
                    int2 c = clamp(int2(floor(p.xz)), int2(0), dim - 1);
                    uint id = floorId.read(uint2(c)).r;
                    alb = flatArr.sample(ts, p.xz, id).rgb;
                    emis = flatEmissive(id);
                    bool liquid = (id == 3u || id == 8u);        // nukage / blood pools — liquid at any depth
                    float wet = max(U.extra.y, liquid ? 1.0 : 0.0);   // depths flood (extra.y); pools always wet
                    reflective = wet > 0.01;                     // a dry industrial deck does NOT mirror
                    float2 fm = flatMaterial(id); rough = fm.x; metal = fm.y;
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
                    } else if (wet > 0.01) {                     // the flooded depths — standing water over the deck
                        float2 q = p.xz;
                        n = normalize(n + float3(cos(q.x * 5.1 + time * 1.1), 0.0,
                                                 cos(q.y * 4.7 - time * 1.3)) * (0.10 * wet));   // slow standing-water ripples
                        alb *= mix(1.0, 0.5, wet);               // the water darkens the deck beneath it
                        rough = mix(rough, 0.08, wet); metal = 0.0;   // standing water glazes the deck glossy
                    } else {                                     // DRY industrial deck
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
                    float2 cm = flatMaterial(id); rough = cm.x; metal = cm.y;
                    // a lamp sits in every other open ceiling cell (the cell over a
                    // ceiling point is always open), so lamps follow the layout
                    if (isLampCell(c)) {
                        float2 ctr = float2(c) + 0.5;
                        float m = max(abs(p.x - ctr.x), abs(p.z - ctr.y));   // 0..0.5
                        if (m < LAMP_HALF) {
                            float face = 1.0 - smoothstep(LAMP_HALF * 0.42, LAMP_HALF, m);   // long soft edge, not a hard square
                            alb = mix(float3(0.06, 0.06, 0.08), LAMP_WARM, face);   // dark housing → warm face
                            emis = 7.5 * face * fixtureFlicker(float2(c), time);   // HDR — blooms + mirrors in the wet floor
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
            const float3 LAMP = float3(0.78, 0.85, 1.00);
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
                lit += (diffAlb * pool + poolSpec) * ao * 0.42;   // warm pools + spec; the colored sector field leads
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
                float shd = 1.0;
                if (li < nShadow) {
                    shd = softShadow(p + n * 0.02, Ld, dl - 0.05, 18.0, dt, s, mapWH, ceilH);
                    if (shd <= 0.0) continue;
                }
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
        float3 col = (base + bloom * (0.42 / 24.0)) * 0.58;      // bloom add + exposure (low-key, moody)
        // teal/amber grade — lift the shadows cool, warm the highlights (the
        // colorimetric move that gives the beauty proof its filmic mood)
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(col * float3(0.84, 0.96, 1.16), col * float3(1.14, 1.0, 0.80), clamp(lum, 0.0, 1.0));
        col *= 1.05;
        col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);   // ACES
        col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));
        float2 d = uv * 2.0 - 1.0;
        col *= 1.0 - 0.34 * dot(d, d);                           // vignette
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
                    // sub-cell centre along the slide axis; empty inside the gap
                    let c = (doorSlidesAlongX(map, cx, cy) ? Float(si) : Float(sj)) * invS + invS * 0.5
                    if abs(c - 0.5) < 0.5 * part { solid = false }           // inside the parted centre gap
                }
                f[j * sw + i] = solid ? 0 : big
            }
        }
        for j in 0..<sh { edt1d(&f, sw, 1, j * sw) }       // rows
        for i in 0..<sw { edt1d(&f, sh, sw, i) }           // columns
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
    static func packCreatures(_ monsters: [Monster], shapeBudget: Int = 360) -> ([GMonster], [GShape]) {
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
            var boundR: Float = 0, hw: Float = 0
            for sh in sl {
                boundR = max(boundR, simd_length(SIMD3(sh.a.x, sh.a.y - boundCY, sh.a.z)) + sh.r1)
                boundR = max(boundR, simd_length(SIMD3(sh.b.x, sh.b.y - boundCY, sh.b.z)) + sh.r2)
                hw = max(hw, simd_length(SIMD2(sh.a.x, sh.a.z)) + sh.r1)   // horizontal half-width
                hw = max(hw, simd_length(SIMD2(sh.b.x, sh.b.z)) + sh.r2)
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
            var scale = min(fit, 0.92 / bodyH) * max(0.34, 1 - m.burn * 0.66)
            // Keep the rendered body within the collision radius so it can't bulge
            // through walls/doors: movement only keeps the CENTER ~radius clear, so a
            // wide pose (extended claws, the Queen's bulk) would otherwise poke past
            // the wall it's pressed against. Clamp world half-width (hw·scale) ≤ radius.
            if hw > 0.001 { scale = min(scale, m.def.radius / hw) }
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

    static func run(outDir: String?) {
        guard let device = MTLCreateSystemDefaultDevice() else { print("Citadel: no Metal device"); return }
        let dir = URL(fileURLWithPath: outDir ?? NSHomeDirectory() + "/Desktop/Citadel-GPU")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let W = RenderConfig.width, H = RenderConfig.viewHeight
        let queue = device.makeCommandQueue()!
        guard let (pipe, post) = makePipelines(device) else { print("Citadel: kernel build failed"); return }
        let wallArr = makeTextureArray(device, Textures.shared.walls)
        let flatArr = makeTextureArray(device, Textures.shared.flats)
        var perfMedians: [(level: Int, ms: Double)] = []

        // sample the building's depth range: floor 1 (dry surface), floor 4 (dry
        // workings), floor 8 (the flooded lowest floor) — so the A/B covers both
        // the dry industrial deck and the standing-water depths
        for level in [1, 4, 8] {
            let world = World(level: level, colonyIndex: level - 1, seed: 1234 &+ UInt64(level))
            let map = world.map
            let (df, sw, sh) = buildDistanceField(map)
            let elights = Lighting.pointLights(map)            // the level's fixtures as dramatic point lights

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

            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1)

            // One reusable run of the live two-pass kernel (raymarch → HDR, post →
            // LDR) against this level's textures; returns GPU execution time (ms)
            // from the command-buffer timestamps, so the very same call renders a
            // shot AND measures the per-frame GPU cost for the 60 fps validation.
            func dispatch(_ u0: Uniforms, _ dyn0: [GPULight], _ monBuf: MTLBuffer, _ shpBuf: MTLBuffer, _ decals0: [SIMD4<Float>]) -> Double {
                var u = u0, dyn = dyn0, decals = decals0
                let cmd = queue.makeCommandBuffer()!
                let enc = cmd.makeComputeCommandEncoder()!
                enc.setComputePipelineState(pipe)
                enc.setTexture(dtTex, index: 0); enc.setTexture(liTex, index: 1); enc.setTexture(hdrTex, index: 2)
                enc.setTexture(wallArr, index: 3); enc.setTexture(flatArr, index: 4)
                enc.setTexture(wallIdT, index: 5); enc.setTexture(floorIdT, index: 6); enc.setTexture(ceilIdT, index: 7)
                enc.setTexture(depthTex, index: 8)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&dyn, length: MemoryLayout<GPULight>.stride * dyn.count, index: 1)
                enc.setBuffer(monBuf, offset: 0, index: 2); enc.setBuffer(shpBuf, offset: 0, index: 3)
                enc.setBytes(&decals, length: MemoryLayout<SIMD4<Float>>.stride * decals.count, index: 4)
                enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                enc.endEncoding()
                let penc = cmd.makeComputeCommandEncoder()!
                penc.setComputePipelineState(post)
                penc.setTexture(hdrTex, index: 0); penc.setTexture(outTex, index: 1)
                penc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                penc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                penc.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
                return (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            }
            func writePNG(_ name: String) {
                let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: W * H)
                outTex.getBytes(buf, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                Captures.writePNG(buf, w: W, h: H, scale: 1, to: dir.appendingPathComponent(name))
                buf.deallocate()
            }
            let nilMon = device.makeBuffer(bytes: [GMonster(a: .zero, b: .zero, c: .zero)], length: MemoryLayout<GMonster>.stride, options: .storageModeShared)!
            let nilShp = device.makeBuffer(bytes: [GShape(a: .zero, b: .zero, col: .zero)], length: MemoryLayout<GShape>.stride, options: .storageModeShared)!

            // ── (1) clean corridor A/B shot — environment only (no prop clutter,
            //        no creatures), camera at the mouth of the longest narrow
            //        corridor looking down it. This is THE still to judge beside
            //        BeautyProof's corridor hero (grade / materials / wet floor /
            //        volumetrics), with nothing else competing for attention. ──
            if let cor = bestCorridorView(map) {
                let dx = cos(cor.dir), dy = sin(cor.dir), plane = RenderConfig.cameraPlane
                let (clights, cshadow) = packLights(elights, camera: cor.pos)   // the fixtures' shaded keys/fills
                let cbuf = clights.isEmpty ? [GPULight(posR: .zero, colI: .zero)] : clights
                let cu = Uniforms(
                    ro: SIMD4(cor.pos.x, 0.5, cor.pos.y, 2.3),
                    fwd: SIMD4(dx, 0, dy, 0),
                    right: SIMD4(-sin(cor.dir) * plane, 0, cos(cor.dir) * plane, 0),
                    up: SIMD4(0, 1, 0, 0),
                    params: SIMD4(Float(W), Float(H), Float(RenderConfig.horizon), 1.0),
                    grid: SIMD4(Float(map.w), Float(map.h), 0, Float(clights.count)),   // emitter lights, no creatures
                    extra: SIMD4(0, Lighting.floodLevel(level: level), Float(cshadow), 0))   // .y = flooding · .z = shadow-casters
                _ = dispatch(cu, cbuf, nilMon, nilShp, [.zero])
                writePNG(String(format: "gpu-corridor-%d.png", level))
            }

            // ── (1b) creature hero shot — a single Queen a few cells down the same
            //        corridor, facing the camera: the headlamp keys her front, a cold
            //        back-light throws a rim, and the native SDF flesh (sub-surface +
            //        silhouette) reads against the dark. The direct A/B to BeautyProof's
            //        creature close-up — the dramatic subject the new lights exist for. ──
            if let cor = bestCorridorView(map) {
                let dx = cos(cor.dir), dy = sin(cor.dir), plane = RenderConfig.cameraPlane
                let cdir = SIMD2<Float>(dx, dy), cside = SIMD2<Float>(-dy, dx)
                let cpos = cor.pos + cdir * 2.6                       // close enough to read, framed down the hall
                var q = Monster(kind: .queen, pos: cpos)
                q.dir = cor.dir + .pi                                 // facing back toward the camera
                q.animTime = 0.25
                var drone = Monster(kind: .alien, pos: cpos - cside * 1.7 + cdir * 0.5)   // a drone flanking her
                drone.dir = cor.dir + .pi + 0.3
                drone.animTime = 0.75
                var (qmons, qshapes) = packCreatures([q, drone])
                if qmons.isEmpty { qmons = [GMonster(a: .zero, b: .zero, c: .zero)] }
                if qshapes.isEmpty { qshapes = [GShape(a: .zero, b: .zero, col: .zero)] }
                let qMonBuf = device.makeBuffer(bytes: qmons, length: MemoryLayout<GMonster>.stride * qmons.count, options: .storageModeShared)!
                let qShpBuf = device.makeBuffer(bytes: qshapes, length: MemoryLayout<GShape>.stride * qshapes.count, options: .storageModeShared)!
                // GAMEPLAY lighting — what the player actually sees: the in-kernel
                // headlamp keys her front, the level's emitter lights give context.
                // No studio key, so this is the true test of the dark-menace shading.
                let (ql0, qsh) = packLights(elights, camera: cpos)
                let qlights = ql0.isEmpty ? [GPULight(posR: .zero, colI: .zero)] : ql0
                let cu = Uniforms(
                    ro: SIMD4(cor.pos.x, 0.5, cor.pos.y, 2.3),
                    fwd: SIMD4(dx, 0, dy, 0),
                    right: SIMD4(-sin(cor.dir) * plane, 0, cos(cor.dir) * plane, 0),
                    up: SIMD4(0, 1, 0, 0),
                    params: SIMD4(Float(W), Float(H), Float(RenderConfig.horizon), 1.0),
                    grid: SIMD4(Float(map.w), Float(map.h), Float(qmons.count), Float(ql0.count)),
                    extra: SIMD4(0, Lighting.floodLevel(level: level), Float(qsh), 0))
                _ = dispatch(cu, qlights, qMonBuf, qShpBuf, [.zero])
                writePNG(String(format: "gpu-creature-%d.png", level))
            }

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
            let muzzle = [GPULight(posR: SIMD4(lpos.x, 0.55, lpos.y, 1 / (radT * radT)),
                                   colI: SIMD4(1.0, 0.8, 0.5, 2.4))]
            let (dyn, dynShadow) = packLights(elights, camera: p.pos, muzzle: muzzle)   // fixtures + the muzzle flash
            u.grid.w = Float(dyn.count)

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
            u.extra.y = Lighting.floodLevel(level: level)         // .y = floor flooding (depths only)
            u.extra.z = Float(dynShadow)                          // .z = leading lights that cast a shadow
            if decals.isEmpty { decals = [SIMD4(0, 0, 0, 0)] }
            if cmons.isEmpty { cmons = [GMonster(a: .zero, b: .zero, c: .zero)] }
            if cshapes.isEmpty { cshapes = [GShape(a: .zero, b: .zero, col: .zero)] }
            let monBuf = device.makeBuffer(bytes: cmons, length: MemoryLayout<GMonster>.stride * cmons.count, options: .storageModeShared)
            let shpBuf = device.makeBuffer(bytes: cshapes, length: MemoryLayout<GShape>.stride * cshapes.count, options: .storageModeShared)

            // ── (2) content shot — the spawn view loaded with one of everything
            //        (creatures, pickups, debris, projectiles, decals, a muzzle
            //        light) to verify every SDF path renders. ──
            _ = dispatch(u, dyn, monBuf!, shpBuf!, decals)
            writePNG(String(format: "gpu-content-%d.png", level))
            print("  wrote gpu-corridor-\(level).png + gpu-content-\(level).png  (grid \(map.w)×\(map.h), DT \(sw)×\(sh))")

            // ── 60 fps validation (#49): time the full-content frame — the
            //    heaviest representative of a real combat frame — at the live
            //    960×480 viewport. Reports GPU execution time only; the per-frame
            //    distance-field rebuild is a separate CPU cost (flagged below). ──
            var times: [Double] = []
            for i in 0..<125 {
                let ms = dispatch(u, dyn, monBuf!, shpBuf!, decals)
                if i >= 5 { times.append(ms) }       // drop warm-up frames
            }
            times.sort()
            let med = times[times.count / 2]
            let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
            print(String(format: "  perf L%d: median %.2f ms → %.0f fps · p95 %.2f ms · best %.2f ms  [%d×%d, full content, GPU-time]",
                         level, med, 1000.0 / med, p95, times.first ?? 0, W, H))
            perfMedians.append((level, med))
        }
        let worst = perfMedians.map { $0.ms }.max() ?? 0
        let verdict = worst <= 16.67
            ? "PASS — every level's median frame is under the 16.67 ms / 60 fps budget"
            : String(format: "OVER the 60 fps budget on the worst level (%.2f ms > 16.67 ms)", worst)
        print(String(format: "Citadel: GPU renders + perf written to %@", dir.path))
        print(String(format: "  60 fps verdict: %@ (worst median %.2f ms → %.0f fps)",
                     verdict, worst, worst > 0 ? 1000.0 / worst : 0))
        print("  NB: GPU-time only — the live renderer also rebuilds the distance field")
        print("      per frame (CPU); cache it across frames where the doors haven't moved.")
    }
}
