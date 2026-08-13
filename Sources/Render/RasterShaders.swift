// Citadel — the rasteriser's Metal shader sources.
//
// Split out of RasterRenderer.swift, which had grown to 4,245 lines — a third of all the render
// code and a sixth of the game — by carrying the renderer, the level-mesh builder, every prop
// tessellator, the frame probe, the shot harness AND these three shaders in one file.
//
// They live in an extension rather than a new type, so every reference elsewhere is unchanged:
// still RasterRenderer.shaderSrc, .fireSrc, .particleSrc. Nothing moved but the text.
//
// Inline Swift strings rather than .metal files, deliberately. Two reasons that have earned their
// keep: the shaders INTERPOLATE Swift constants (WorldLight.lampColor is written straight into the
// lighting maths, so the CPU bake and the GPU shading cannot drift apart), and a single-target
// swiftc build has no .metal compile step to hang them off.
//
// The cost of that choice, worth knowing: Metal compiles these at FIRST DISPATCH, not at build
// time — so a syntax error here is a RUNTIME failure, invisible to `gmake build`. Any change to
// this file must be run through a harness (CITADEL_RASTERSHOT is enough) before it is believed.

import Foundation
import Metal

extension RasterRenderer {
    // ════════════════════════════════════════════════════════════════════════
    static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;

    // overhead ceiling-lamp grid constants — injected from the RasterRenderer statics so the
    // shader's analytic lamps, buildMesh's housings, and the presence mask share one definition.
    constant int    kStride    = \(RasterRenderer.lampGridStride);
    constant int    kPhase     = \(RasterRenderer.lampGridPhase);
    constant float  kGridStep  = \(Float(RasterRenderer.lampGridStride));
    constant float  kGridOff   = \(Float(RasterRenderer.lampGridPhase) + 0.5);   // lamp centre = kStride·k + kPhase + 0.5
    constant float3 kLampCol   = float3(\(WorldLight.lampColor.x), \(WorldLight.lampColor.y), \(WorldLight.lampColor.z));
    constant float  kLampInt   = \(RasterRenderer.lampIntensity);
    // How much of the floor's baked light an UPWARD reflection is allowed to see. Not zero: the
    // ceiling is lit by the same fixtures, just far more weakly than the floor they point at.
    constant float  kEnvCeil   = 0.18;
    constant float  kLampInvR2 = \(1 / (RasterRenderer.lampPoolRadius * RasterRenderer.lampPoolRadius));   // 1/radius²
    constant float  kLampY     = \(RasterRenderer.lampLightY);

    struct Cam { float4x4 mvp; float4x4 lmvp[3]; float4 eye; float4 params; float4 amb; float4 headFwd; float4 shX; float4 shZ; float4 camFwd; float4 water; };
    struct Light { float4 posR; float4 colI; };          // posR=(x,y,z,1/r²)  colI=(rgb,intensity)
    struct PV { float px,py,pz, nx,ny,nz, ar,ag,ab, rough, metal, er,eg,eb, tid; };
    struct VOut { float4 clip [[position]]; float3 wp; float3 wn; float3 alb; float rgh; float mtl; float3 emis; float2 uv; float tid; };
    struct SOut { float4 clip [[position]]; };

    float h21(float2 p){ p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.5); return fract(p.x*p.y); }
    float vnoise(float2 p){ float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
        float a=h21(i),b=h21(i+float2(1,0)),c=h21(i+float2(0,1)),d=h21(i+float2(1,1));
        return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
    float fbm(float2 p){ float s=0,a=0.5; for(int i=0;i<5;i++){ s+=a*vnoise(p); p*=2.03; a*=0.5;} return s; }
    // Height field for BLASTED ROCK: a few octaves with a ridged fold, so faces break into chunky planes
    // separated by sharp fractures rather than rolling smoothly. Sampled in the wall's own tangent plane and
    // differenced for the normal — that gradient, not the baked colour, is what makes rock read as rock.
    // One Voronoi layer of TILTED PLANES: each cell is a facet, and because dot(offset, dir) is linear inside
    // a cell every facet differentiates to a constant normal, so neighbours meet at a sharp crease — how
    // fractured stone actually breaks. (Smooth fbm ridges read as brain coral; stacked fbm reads as moss.)
    float voroFacet(float2 p, float seed){
        float2 ip = floor(p), fp = fract(p);
        float bd = 1e9, bid = 0.0; float2 br = float2(0.0);
        for(int j=-1;j<=1;j++){ for(int i=-1;i<=1;i++){
            float2 g = float2(float(i), float(j));
            float2 o = float2(h21(ip+g+seed), h21(ip+g+seed+31.7));    // jittered site in that cell
            float2 r = g + o - fp;
            float d = dot(r,r);
            if(d < bd){ bd = d; br = r; bid = h21(ip+g+seed+7.3); }
        }}
        float a = bid * 6.2831853;                                     // per-facet tilt direction
        return bid*0.55 + dot(br, float2(cos(a), sin(a)))*0.45;
    }
    float rockH(float2 p){
        // A raw Voronoi alone reads as regular CRAZY PAVING, so DOMAIN-WARP it first: the cells stretch and
        // shear into irregular shards. Two scales — big broken chunks plus smaller chips knocked off their
        // edges — then a whisper of grit.
        float2 q = p * 2.4;
        q += float2(fbm(q*0.5), fbm(q*0.5 + 19.0)) * 1.5;
        return voroFacet(q, 0.0) * 1.00
             + voroFacet(q*2.7 + 13.0, 5.0) * 0.28
             + vnoise(q*4.0) * 0.06;
    }
    // ── M6 standing water: the INTEGER-hash value-noise puddle field, byte-identical to
    // Lighting.puddle / GPURaymarch.puddleField, so the raster water pools EXACTLY where the
    // game wades + drips and the raymarcher draws it (the fixtureBusted lockstep trick). ──
    uint  rIhash(int x,int y){ uint h=uint(x)*374761393u+uint(y)*668265263u; h=(h^(h>>13))*1274126177u; return h^(h>>16); }
    float rIhash01(int x,int y){ return float(rIhash(x,y)&0xFFFFu)/65535.0; }
    float rInoise2(float2 q){ float2 i=floor(q),f=fract(q); f=f*f*(3-2*f); int2 c=int2(i);
        float a=rIhash01(c.x,c.y),b=rIhash01(c.x+1,c.y),cc=rIhash01(c.x,c.y+1),d=rIhash01(c.x+1,c.y+1);
        return mix(mix(a,b,f.x),mix(cc,d,f.x),f.y); }
    float rPuddleField(float2 xz){ return 0.65*rInoise2(xz*0.55)+0.35*rInoise2(xz*1.9+31.0); }
    float rPuddleMask(float f){ return smoothstep(0.50,0.60,f); }
    float3 triNoise(float3 wp, float3 n, float scale){
        float3 an=abs(n); an/=(an.x+an.y+an.z);
        float2 uvX=wp.zy*scale, uvY=wp.xz*scale, uvZ=wp.xy*scale; float e=0.35/scale;
        float vX=fbm(uvX), vY=fbm(uvY), vZ=fbm(uvZ);
        return float3(vX*an.x+vY*an.y+vZ*an.z, fbm(uvY+float2(e,0))-vY, fbm(uvY+float2(0,e))-vY);
    }
    float D_GGX(float ndh,float a){ float a2=a*a; float d=ndh*ndh*(a2-1)+1; return a2/(3.14159265*d*d+1e-6); }
    float G_Smith(float ndv,float ndl,float a){ float k=(a+1)*(a+1)/8; float gv=ndv/(ndv*(1-k)+k); float gl=ndl/(ndl*(1-k)+k); return gv*gl; }
    float3 F_Schlick(float vdh,float3 f0){ return f0 + (1-f0)*pow(1.0-vdh,5.0); }

    vertex VOut rr_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant Cam& C [[buffer(1)]]){
        PV p=vs[vid]; float3 wp=float3(p.px,p.py,p.pz);
        VOut o; o.clip=C.mvp*float4(wp,1); o.wp=wp; o.wn=normalize(float3(p.nx,p.ny,p.nz));
        o.alb=float3(p.ar,p.ag,p.ab); o.rgh=p.rough; o.mtl=p.metal; o.emis=float3(p.er,p.eg,p.eb);
        // wall texture UV: along-wall (world X or Z by facing) × height, tiled per cell (repeat sampler). Flip
        // the along-wall axis by the wall's NORMAL sign so baked directional art (the ARC seal, door glyphs)
        // reads the SAME way from the side that's actually open — otherwise it mirrors on opposite facings.
        float wu = abs(o.wn.x) > 0.5 ? (o.wn.x > 0.0 ? -wp.z : wp.z) : (o.wn.z > 0.0 ? wp.x : -wp.x);
        o.uv=float2(wu, 1.0 - wp.y); o.tid=p.tid; return o;
    }
    vertex SOut rr_shadow_vertex(uint vid [[vertex_id]], constant PV* vs [[buffer(0)]], constant float4x4& lmvp [[buffer(2)]]){
        PV p=vs[vid]; SOut o; o.clip=lmvp*float4(p.px,p.py,p.pz,1); return o;
    }

    // Soft cast shadow from one lamp's ORTHO top-down slice. A 16-tap Poisson disk over a
    // WIDE radius gives a diffused penumbra (real fixtures never cast razor edges); ortho, so
    // clip.w=1 and clip.xyz are already NDC. Outside this lamp's covered square → unshadowed.
    constant float2 kPoisson[16] = {
        float2(-0.326,-0.406), float2(-0.840,-0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
        float2( 0.962,-0.195), float2( 0.473,-0.480), float2( 0.519, 0.767), float2( 0.185,-0.893),
        float2( 0.507, 0.064), float2( 0.896, 0.412), float2(-0.322,-0.933), float2(-0.792,-0.598),
        float2( 0.080, 0.990), float2(-0.985, 0.144), float2(-0.126, 0.113), float2( 0.235, 0.386) };
    float pcfLamp(depth2d_array<float> smap, uint slice, float3 wp, float4x4 lmvp){
        float3 ndc=(lmvp*float4(wp,1)).xyz;               // ortho → w==1
        float2 uv=float2(ndc.x*0.5+0.5, 0.5-ndc.y*0.5);
        if(any(uv<float2(0.0))||any(uv>float2(1.0))||ndc.z<0.0||ndc.z>1.0) return 1.0;
        constexpr sampler ss(coord::normalized, address::clamp_to_edge, filter::linear);
        float bias=0.004, lit=0, r=22.0/1024.0;           // r = penumbra radius — WIDE (~0.15 m world) for soft diffused edges, never razor-sharp
        for(int j=0;j<16;j++){ float d=smap.sample(ss, uv+kPoisson[j]*r, slice); lit += (ndc.z-bias<=d)?1.0:0.0; }
        return lit/16.0;
    }

    // per-id wall self-illumination (matches GPURaymarch.wallEmissive): litPanel/computer/exit/doors glow
    inline float wallEmis(uint id){
        if(id==4u) return 0.85; if(id==16u) return 1.05; if(id==10u) return 0.60;
        if(id==13u||id==14u||id==15u||id==17u) return 0.45; if(id==18u) return 0.5; return 0.0;
    }
    struct RROut { float4 color [[color(0)]]; float perp [[color(1)]]; };
    fragment RROut rr_fragment(VOut in [[stage_in]], constant Cam& C [[buffer(1)]],
                                constant Light* lights [[buffer(2)]],
                                constant float4* decals [[buffer(3)]],
                                depth2d_array<float> smap [[texture(0)]], texture2d<float> field [[texture(1)]],
                                texture2d<float> lampMask [[texture(2)]], texture2d<uint> floorId [[texture(3)]],
                                texture2d_array<float> wallArr [[texture(4)]]){
        float3 alb=in.alb; float rough=in.rgh, metal=in.mtl; float wemis=0.0; float3 wallGlow=float3(0.0);
        if(in.tid>=0.0){                                    // TEXTURED WALL — the SAME baked art the raymarcher samples
            constexpr sampler ws(address::repeat, filter::linear);
            uint wid=uint(in.tid+0.5);
            alb=wallArr.sample(ws, in.uv, wid).rgb;
            wemis=wallEmis(wid);                            // self-lit fixtures (CRT screens, strip-lights) → bloom in the HDR pass
            float wt=C.amb.y;                               // time
            if(wid==10u){
                // COMPUTER BANK — live ANIMATED amber monitors (ported from the SDF renderer): a 4×4 grid,
                // each a distinct readout (scrolling log · oscilloscope · spectrum · dashboard), pure
                // time-driven math OVER the baked screen so the content genuinely MOVES.
                float2 g4=in.uv*4.0; float2 mcell=floor(g4); float2 muv=fract(g4);
                float mh=h21(mcell), mh2=h21(mcell+7.0); bool dead=h21(mcell+19.0)>0.86;
                float2 s=(muv-0.09)/0.82;
                if(s.x>0.0&&s.x<1.0&&s.y>0.0&&s.y<1.0&&!dead){
                    float sp=0.6+1.6*mh2;
                    float glow=0.05*(step(0.92,fract(s.x*8.0))+step(0.92,fract(s.y*6.0)));   // graticule
                    if(mh<0.34){ float ry=s.y*13.0+wt*(1.3+sp); float row=floor(ry);          // SCROLLING LOG
                        float len=0.15+0.80*h21(float2(row,mcell.x+mcell.y*3.0));
                        float ch=step(0.40,fract(s.x*16.0+h21(float2(row,2.0))*17.0));
                        glow+=0.85*ch*step(s.x,len)*step(0.20,fract(ry)); }
                    else if(mh<0.56){ float y=0.5+0.20*sin(s.x*16.0+wt*(3.0+sp))+0.09*sin(s.x*37.0-wt*(5.0+sp));
                        glow+=1.0-smoothstep(0.0,0.035,abs(s.y-y)); }                           // OSCILLOSCOPE
                    else if(mh<0.78){ float bar=floor(s.x*14.0);                                // SPECTRUM
                        float h=0.12+0.80*pow(0.5+0.5*sin(wt*(2.4+sp)+bar*0.8+mh*6.0),2.0);
                        glow+=0.85*step(s.y,h)*step(0.28,fract(s.x*14.0)); }
                    else { if(s.y>0.64){ float meter=(s.y>0.82)?0.45+0.45*sin(wt*(1.4+sp)):0.30+0.55*fract(wt*0.35+mh);
                            glow+=0.85*step(s.x,meter)*step(0.10,fract(s.x*26.0)); }            // DASHBOARD
                        else if(s.y>0.28){ float row=floor(s.y*8.0+wt*(0.8+sp));
                            glow+=0.80*step(0.50,fract(s.x*18.0+row*4.0))*step(s.x,0.92); }
                        else { glow+=1.0-smoothstep(0.0,0.03,abs(s.y-(0.14+0.09*sin(s.x*26.0+wt*4.0)))); } }
                    glow*=0.9+0.15*(0.6+0.4*sin(wt*31.0+mh*17.0));                              // tube flicker
                    // Content lives ONLY in the emissive term; the glass stays near-BLACK so unlit screen
                    // reads black (high contrast), and glow² crushes the graticule/dim mids so only the
                    // real readout glows + blooms — no tan wash.
                    alb=float3(0.006,0.004,0.002); rough=1.0; metal=0.0;                        // near-BLACK MATTE CRT glass — no amber env-spec sheen, room can't lift it
                    wallGlow=float3(1.0,0.60,0.13)*pow(clamp(glow,0.0,1.5),1.5)*2.5;            // amber content, self-lit (γ crush → dark mids, bright readout)
                    wemis=0.0;
                } else { alb=dead?float3(0.012,0.012,0.014):float3(0.02,0.022,0.026); rough=1.0; wemis=0.0; }  // dark MATTE steel bezel / dead unit → blacks read black
            } else if(wid==21u){
                // ── THE BIG BOARD (ops centre) ── the ONE full-colour display in the colony: everything else
                // is amber phosphor, so the plot board reads as the room that matters. Four panels, each a live
                // operational picture: ORBITAL ground-track, MINING shaft/tonnage, SHIPPING manifest+bays, and
                // LAUNCH pad status. Drawn per-fragment so it genuinely moves — a static plot board is a poster.
                float2 g2 = in.uv * float2(0.5, 2.0);                               // BIG panels: one per 2 cells, 2 high
                float2 pc = floor(g2); float2 q = fract(g2);
                // PARITY, not the raw cell index: the along-wall coordinate grows without bound and goes
                // NEGATIVE (the U axis flips by wall facing), so indexing on it put every panel in one branch.
                float ax = fract(pc.x * 0.5) * 2.0, ay = fract(pc.y * 0.5) * 2.0;    // each 0 or 1
                float panel = ax + ay * 2.0;                                         // 0..3
                float2 s = (q - 0.055) / 0.89;                                      // inside the bezel
                float3 pic = float3(0.0);
                if(s.x > 0.0 && s.x < 1.0 && s.y > 0.0 && s.y < 1.0){
                    float grid = 0.035 * (step(0.965, fract(s.x*10.0)) + step(0.965, fract(s.y*7.0)));
                    if(panel < 0.5){
                        // ORBITAL OPERATIONS — a ground track sinusoid crawling over a plate carrée world
                        pic += float3(0.05,0.12,0.22) + float3(0.0,0.10,0.18)*grid*4.0;         // ocean
                        float land = vnoise(float2(s.x*7.0, s.y*4.0));
                        pic = mix(pic, float3(0.10,0.26,0.14), smoothstep(0.52,0.60,land));      // landmass
                        float track = 0.5 + 0.30*sin(s.x*9.4 - wt*0.30);
                        pic += float3(0.20,1.00,0.55) * (1.0 - smoothstep(0.0,0.010,abs(s.y-track)));
                        float sx = fract(wt*0.055);                                              // the vehicle
                        float d2 = length((s - float2(sx, 0.5 + 0.30*sin(sx*9.4 - wt*0.30))) * float2(1.0,1.6));
                        pic += float3(1.0,0.85,0.30) * (1.0 - smoothstep(0.0,0.030,d2));
                    } else if(panel < 1.5){
                        // MINING — shaft section with ore seams + a live tonnage histogram
                        pic += float3(0.16,0.13,0.10)*(0.5+0.5*vnoise(float2(s.x*9.0,s.y*9.0))) + grid;
                        float seam = vnoise(float2(s.x*5.0, s.y*3.0 + 11.0));
                        pic = mix(pic, float3(0.95,0.55,0.12), smoothstep(0.62,0.72,seam)*0.85); // ore seam
                        if(s.y < 0.42){                                                          // tonnage bars
                            float b = floor(s.x*11.0);
                            float hgt = 0.06 + 0.34*pow(0.5+0.5*sin(wt*0.9 + b*1.7), 1.6);
                            float on = step(s.y, hgt) * step(0.18, fract(s.x*11.0));
                            pic = mix(pic, mix(float3(0.15,0.85,0.35), float3(0.95,0.25,0.15), smoothstep(0.22,0.38,hgt)), on);
                        }
                        pic += float3(0.9,0.15,0.10) * step(0.985, fract(wt*0.5)) * 0.6;         // fault klaxon flash
                    } else if(panel < 2.5){
                        // SHIPPING — a cargo-bay allocation grid beside a scrolling manifest
                        pic += float3(0.05,0.06,0.09) + grid;
                        if(s.x < 0.52){                                                          // bay grid
                            float2 c2 = floor(float2(s.x*7.0, s.y*6.0));
                            float st = h21(c2 + floor(wt*0.20));
                            float3 col = st > 0.72 ? float3(0.15,0.80,0.35) : (st > 0.42 ? float3(0.95,0.72,0.12) : float3(0.20,0.28,0.40));
                            float ins = step(0.14, fract(s.x*7.0)) * step(0.16, fract(s.y*6.0));
                            pic = mix(pic, col, ins*0.9);
                        } else {                                                                 // manifest rows
                            float row = floor(s.y*12.0 + wt*0.55);
                            float len = 0.10 + 0.34*h21(float2(row, 3.0));
                            float ch = step(0.42, fract((s.x-0.54)*22.0 + h21(float2(row,7.0))*13.0));
                            pic += float3(0.55,0.85,1.00) * ch * step(s.x-0.54, len) * step(0.22, fract(s.y*12.0 + wt*0.55));
                        }
                    } else {
                        // LAUNCH / LANDING — pad status lamps over an ascent profile
                        pic += float3(0.04,0.05,0.07) + grid;
                        float prof = pow(clamp(s.x*1.15, 0.0, 1.0), 2.2);                        // ascent curve
                        pic += float3(0.35,0.75,1.00) * (1.0 - smoothstep(0.0,0.012,abs(s.y - 0.10 - prof*0.72)));
                        for(int pi = 0; pi < 4; pi++){                                           // four pads
                            float fx2 = 0.13 + float(pi)*0.25;
                            float ph2 = fract(wt*0.13 + float(pi)*0.31);
                            float3 lamp = ph2 < 0.45 ? float3(0.15,0.85,0.30) : (ph2 < 0.75 ? float3(0.95,0.70,0.10) : float3(0.95,0.20,0.12));
                            float d3 = length((s - float2(fx2, 0.88)) * float2(1.0,1.5));
                            pic += lamp * (1.0 - smoothstep(0.012,0.030,d3));
                        }
                        float cd = fract(wt*0.09);                                               // countdown bar
                        pic += float3(0.95,0.85,0.25) * step(s.y,0.055) * step(s.x,cd) * step(0.03,s.y);
                    }
                    pic *= 0.94 + 0.10*sin(wt*23.0 + panel*5.0);                                 // panel refresh shimmer
                }
                wallGlow += pic * 0.45;
            } else if(wid==4u){
                wemis*=0.86+0.14*sin(wt*9.0+h21(floor(in.wp.xz))*23.0);                         // litPanel/bulkhead strip: gentle flicker
            }
        }
        float3 gn=normalize(in.wn);
        // Surfaces are CONTINUOUS — no per-metre panel grid (that read as tiled squares). Large-scale
        // form + grime come from the tri-planar noise below; real panel JOINTS are authored into the
        // map's materials, not stamped on every cell.
        float3 tn=triNoise(in.wp, gn, 5.5);
        float3 T=normalize(abs(gn.y)<0.9?cross(float3(0,1,0),gn):float3(1,0,0)), B=cross(gn,T);
        float3 N=normalize(gn - (tn.y*T+tn.z*B)*0.3);
        float grime=tn.x; rough=clamp(rough+(grime-0.5)*0.32,0.05,1.0); alb *= (0.74+0.48*grime);

        // ── BLASTED ROCK (wall ids 8 stone · 9 stoneSteel) ── the baked art alone reads as flat CAMO blotches:
        //    rock needs 3-D form. Compress the blotchy albedo toward one stone hue, then rebuild the surface
        //    from multi-scale triplanar noise: chunky broken faces, chisel/blast fractures cut as sharp creases,
        //    and crevice AO. The normal — not the colour — is what makes it read as hewn rock.
        if(in.tid >= 7.5 && in.tid < 9.5){
            // 1. KILL THE CAMO: the baked art's blotches live in its luminance, so compress that range hard to
            //    one dry stone hue. Colour must stay near-uniform — the FORM has to come from the normal.
            float lum = dot(alb, float3(0.299,0.587,0.114));
            float flat = 0.5 + (lum - 0.5) * 0.18;                        // ±0.09 instead of the full swing
            alb = float3(0.335,0.305,0.272) * (0.72 + 0.56*flat);
            // 2. REBUILD THE SURFACE from a height field sampled in the wall's OWN tangent plane, differenced
            //    for a correct gradient (the triplanar helper's derivatives are Y-plane only — wrong on a
            //    vertical face, which is why the wall stayed flat).
            float2 rp = float2(dot(in.wp, T), dot(in.wp, B));
            float e = 0.045;
            float hC = rockH(rp);
            float2 grad = float2(rockH(rp + float2(e,0)) - hC, rockH(rp + float2(0,e)) - hC) / e;
            N = normalize(gn - (T*grad.x + B*grad.y) * 0.38);             // chunky broken faces
            // 3. crevice AO + a touch of dust catching on the up-facing ledges
            float lowness = smoothstep(1.05, 0.35, hC);                   // 1 deep in a fracture, 0 on a proud face
            alb *= mix(1.0, 0.62, lowness);                               // gentle: heavy AO outlines every facet like mortar
            alb *= 0.88 + 0.24 * smoothstep(0.0, 0.5, dot(N, float3(0,1,0)));   // ledges lighter (settled dust)
            rough = clamp(0.88 + 0.10*fbm(rp*22.0), 0.74, 0.99);          // dry, matte, never shiny
            metal = 0.0;
        }

        // ── FUEL DRUM weathering (tid≈−5) — a matte, rusted, ribbed industrial barrel, ported from the
        //    raymarcher's drum branch so raster drums read the same: rolling hoops, mottled rust eating the
        //    paint, streaks bleeding down, a darker steel lid. (Emitted matte: metal 0.20, rough 0.86.)
        if(in.tid < -4.5 && in.tid > -5.5){
            float3 rust = float3(0.30,0.12,0.055), rustDk = float3(0.17,0.07,0.035);
            float py = in.wp.y;                                                        // barrel stands base≈0, top≈0.45
            alb = mix(alb, alb*0.5, smoothstep(0.58,0.9,gn.y));                         // darker flat steel lid
            alb *= mix(0.62, 1.0, smoothstep(0.0,0.13,py));                             // grime pooled at the base
            float rib = max(smoothstep(0.022,0.0,abs(py-0.15)), smoothstep(0.022,0.0,abs(py-0.32)));
            alb *= 1.0 - 0.52*rib;                                                      // two rolling hoops (recessed bands)
            // HIGH frequencies: a barrel is only ~0.3 wide, so the rust must vary across that span
            float big = fbm(in.wp.xz*13.0 + py*4.0);                                    // large rust blooms
            float fine = fbm(in.wp.xz*36.0);                                            // + fine pitting
            float patch = 0.6*big + 0.4*fine;
            float rustA = smoothstep(0.46,0.72,patch);                                  // moderate coverage → the clean paint stays glossy metal
            float streak = smoothstep(0.55,0.92, fbm(float2((in.wp.x-in.wp.z)*24.0, py*1.5))) * clamp(1.15-py*1.5,0.2,1.0);
            alb = mix(alb, rust, rustA*0.85);                                           // mottled rust eating the paint
            alb = mix(alb, rustDk, smoothstep(0.72,0.9,patch)*0.8);                     // deep rust cores
            alb = mix(alb, rust*0.6, streak*0.6);                                       // streaks bleed down from the rim
            float rf = clamp(rustA + streak*0.5, 0.0, 1.0);                             // 0 clean → 1 rusty
            metal = mix(0.80, 0.10, rf);                                                // GLOSSY painted steel where clean; matte where rust eats it
            rough = mix(0.30, 0.92, rf);
        }

        // ── PLANT MACHINERY (tid ≈ −6) ── the imported machines on floors 7–8. These are WORKING kit
        // that has stood in a wet hole for years, and bare geometry with two flat materials read as
        // exactly that: a blank sheet under the headlamp, and an unreadable dark mass away from it.
        // Three treatments break a panel up, and they have to OPPOSE each other to register — matte
        // rust, glossy oil, pale dust. Same darkness with a different finish is what the eye picks up.
        if(in.tid < -5.5 && in.tid > -6.5){
            float py = in.wp.y;                                                         // base ≈ 0, top ≈ 1.0–1.6
            // Offsetting the noise field BY HEIGHT is load-bearing, not decoration: a vertical face has
            // only one xz coordinate down its whole span, so plain fbm(wp.xz) would smear into vertical
            // stripes — the same trap the rock walls fell into before the tangent-plane rewrite. Adding
            // py makes the field vary in every direction on every facing, for one multiply.
            // Frequencies are far LOWER than the drums' 13/36: those were tuned for a 0.3-wide barrel,
            // and these machines are 1.0–2.8 across, where that rate turns to visual noise at any range.
            float bloom = fbm(in.wp.xz*5.5 + py*3.1);
            float fine  = fbm(in.wp.xz*15.0 + py*7.0);
            float patch = 0.62*bloom + 0.38*fine;
            // MOTTLE EVERYWHERE, before any rust. Coverage alone does not fix a blank panel: wherever the
            // rust mask happened to miss, the paint was still perfectly uniform and still read as sheet
            // metal off a roll. Worn paint is never one value, so vary all of it — the rust below then
            // sits on a surface that already has life rather than doing the whole job itself.
            alb *= 0.76 + 0.34*patch;
            rough = mix(rough, min(1.0, rough + 0.12), fine);
            float rustA = smoothstep(0.40, 0.70, patch);
            // STREAKS — rust bleeds DOWN from seams and fixings, and it is the single strongest cue
            // that something has been left standing in the damp. Stretching the noise along Y draws the
            // blotches out into runs; without this the rust reads as camouflage, not corrosion.
            float streak = smoothstep(0.44, 0.82, fbm(float2((in.wp.x - in.wp.z)*11.0, py*1.1)));
            streak *= smoothstep(0.02, 0.30, py);                                       // runs start off the deck, not at the feet
            float3 rust = float3(0.28,0.12,0.055), rustDk = float3(0.15,0.065,0.03);
            alb = mix(alb, rust, rustA*0.86);
            alb = mix(alb, rustDk, smoothstep(0.76,0.93,patch)*0.75);                   // deep cores where it has eaten through
            alb = mix(alb, rust*0.55, streak*0.62);
            float rf = clamp(rustA + streak*0.45, 0.0, 1.0);
            rough = mix(rough, 0.95, rf);
            metal = mix(metal, 0.06, rf);                                               // oxide is not metal
            // OIL — a wet film wicking up from the greased deck. GLOSSY, which is the whole point: it
            // sits at the same darkness as the rust, so only the finish separates them.
            float oil = clamp(1.0 - py/0.55, 0.0, 1.0);
            oil *= 0.45 + 0.55*fbm(in.wp.xz*8.0 + py*2.0);
            alb *= 1.0 - 0.62*oil;
            rough = mix(rough, 0.16, oil*0.8);
            metal = mix(metal, 0.50, oil*0.45);
            // DUST settles on whatever faces the roof, and it is the only PALE term here — so it peels
            // the horizontal surfaces away from the vertical ones without a second material.
            float up = smoothstep(0.45, 0.95, gn.y);
            alb = mix(alb, float3(0.20,0.19,0.17), up*0.42*(0.55+0.45*fine));
            rough = mix(rough, 0.92, up*0.5);
        }

        // ── M5 aftermath DECALS on FLOOR fragments (blood/scorch/scattered-papers/ash/offal) — ported
        // from the raymarch floor blend; modifies alb (+ a self-lit term) BEFORE the PBR lighting below.
        // Cheap AABB→circle reject so uncovered floor pixels pay almost nothing (nD>0 across the deck). ──
        float decalEmis = 0.0;
        int nD = int(C.amb.x);
        // NOT ON THE HELD WEAPON. Both this block and the floor-liquid block below identify "the floor"
        // as any UP-FACING fragment and then treat it by its world XZ — and the gun is a fistful of
        // up-facing faces sitting at the marine's own XZ. So whatever she was standing on was painted
        // straight onto her weapon: a grating drew a grating on the barrel, and a blood pool turned the
        // whole gun red. That is what "the floor is reflecting on the barrel" was, all along — not a
        // reflection, not the ambient, not the rail's albedo, but the deck's own decals applied to it.
        bool isVM = (C.amb.z > 0.5);
        if(nD > 0 && gn.y > 0.5 && !isVM){
            float dtime = C.amb.y, dn = -1.0;
            for(int di=0; di<nD; di++){
                float4 dc = decals[di];
                float2 dxz = in.wp.xz - dc.xy; float rad = max(dc.z, 0.05);
                if(abs(dxz.x) >= rad || abs(dxz.y) >= rad) continue;
                float dd2 = dot(dxz, dxz); if(dd2 >= rad*rad) continue;
                if(dn < 0.0) dn = 0.5 + 0.5*fbm(in.wp.xz*3.3 + 5.0);
                float rr = sqrt(dd2)/rad;
                float fall = (1.0 - smoothstep(0.15, 1.0, rr)) * (0.62 + 0.38*dn);   // solid core, noise erodes the rim
                if(dc.w > 3.0){                                               // scattered papers
                    float st = clamp(dc.w - 3.0, 0.0, 1.0);
                    float2 q = in.wp.xz - dc.xy; float cover = 0.0, tone = 0.9;
                    for(int sk=0; sk<6; sk++){
                        float s = float(sk)*1.7 + dc.x*3.1 + dc.y*5.7;
                        float2 cc = (float2(fract(sin(s*12.9)*4137.1), fract(sin(s*78.2)*2619.7)) - 0.5) * (dc.z*1.2);
                        float ang = fract(sin(s*37.7)*7351.3) * 6.2831853;
                        float2 hs = float2(0.085 + 0.05*fract(sin(s*5.3)*1234.5), 0.11 + 0.06*fract(sin(s*9.1)*9182.3));
                        float2 dq = q - cc;
                        float2 lp2 = float2(dq.x*cos(ang) + dq.y*sin(ang), -dq.x*sin(ang) + dq.y*cos(ang));
                        float ins = smoothstep(-0.004, 0.004, min(hs.x - abs(lp2.x), hs.y - abs(lp2.y)));
                        if(ins > cover){ cover = ins; tone = 0.86 + 0.16*fract(sin(s*3.3)*111.1); }
                    }
                    cover *= st;
                    alb = mix(alb, float3(0.86,0.84,0.77)*tone, cover); decalEmis += cover*0.20;
                } else if(dc.w > 2.0){                                        // smoldering ash + live embers
                    float st = clamp(dc.w - 2.0, 0.0, 1.0), lump = vnoise(in.wp.xz*26.0);
                    float ash = smoothstep(0.45, 0.70, lump)*fall*st;
                    alb = mix(alb, float3(0.07,0.065,0.06), min(1.0, ash*1.8));
                    float fleck = smoothstep(0.80, 0.95, lump)*fall*st, glowT = 0.55 + 0.45*sin(dtime*2.3 + lump*37.0);
                    alb = mix(alb, float3(0.9,0.35,0.08), fleck*glowT*0.8); decalEmis += fleck*glowT*0.5;
                } else if(dc.w >= 0.0){ alb *= 1.0 - 0.93*fall*dc.w;          // scorch → charred black
                } else if(dc.w > -2.0){ float b = clamp(fall*(-dc.w)*1.1, 0.0, 1.0);   // blood → dark wet pool
                    alb = mix(alb, float3(0.13,0.014,0.011), b);
                } else {                                                      // offal (gibbed remains)
                    float st = clamp(-(dc.w+2.0), 0.0, 1.0), lump = vnoise(in.wp.xz*22.0);
                    float meat = smoothstep(0.55, 0.75, lump)*fall*st;
                    alb = mix(alb, float3(0.30,0.035,0.03), min(1.0, meat*1.7));
                    float glisten = smoothstep(0.74, 0.92, lump)*fall*st;
                    alb = mix(alb, float3(0.52,0.10,0.08), glisten);
                }
            }
        }

        // ── M6 LIQUIDS on FLOOR fragments: toxic pools (nukage), blood pools, the drowned lowest
        // floor, and floor-7's rock puddles — an animated wet surface. The floor id (read by integer
        // cell) tells liquid from pooling-rock; the flood scalar drowns the lowest floor; the puddle
        // field (byte-identical to the game's, so you splash exactly where you see water) says where
        // the rock pools. Mirrors the raymarch floor-liquid blend: churn the normal, glaze it glossy,
        // darken + cool the bed, and (nukage) pulse the glow. Applied BEFORE the PBR lighting below. ──
        float3 waterEmis = float3(0.0);
        if(gn.y > 0.5 && !isVM){                                        // see isVM above — the gun is not the floor
            uint2 fc = uint2(clamp(int2(floor(in.wp.xz)), int2(0), int2(int(C.params.z)-1, int(C.params.w)-1)));
            int fid = int(floorId.read(fc).r);
            bool liquid = (fid == 3 || fid == 8);                       // nukage / blood — liquid at any depth
            // FLOOR GRATE (fid 2) — raster floors are flat materials (only walls are textured), so a vent's
            // grate cell read as plain deck and the steam looked like it rose out of solid concrete. Draw the
            // grate procedurally: a recessed dark duct behind slotted iron bars, with a bevelled kerb frame.
            if(fid == 2){
                float2 g = fract(in.wp.xz);
                float2 e = min(g, 1.0 - g);                              // distance to the cell edge
                float kerb = smoothstep(0.10, 0.06, min(e.x, e.y));      // raised frame around the opening
                float slot = 1.0 - smoothstep(0.16, 0.30, abs(fract(in.wp.x * 9.0) - 0.5));   // bar/gap run
                float duct = slot * (1.0 - kerb);                        // the dark gaps between the bars
                alb = mix(alb * (0.55 + 0.35 * kerb), float3(0.020, 0.021, 0.023), duct * 0.88);
                rough = mix(rough, 0.42, 1.0 - duct);                    // worn iron bars catch a little sheen
                metal = mix(metal, 0.62, 1.0 - duct);
            }
            // PLANT DECK STAINS (floors 7–8, flagged by C.water.w == 0 — those floors run no ceiling grid):
            // the deck stays SMOOTH, but decades of machinery leave it stained — broad dark grease pools,
            // spilled-lubricant slicks that go glossy, and a scatter of drip marks. Albedo + roughness only.
            if(C.water.w < 0.5 && !liquid){
                float2 q = in.wp.xz;
                float pool  = smoothstep(0.52, 0.86, fbm(q*0.55));               // big soaked-in grease patches
                float slick = smoothstep(0.68, 0.93, fbm(q*1.9 + 17.0));         // fresher lubricant, still wet-looking
                float drips = smoothstep(0.80, 0.97, fbm(q*7.5 + 43.0));         // small drip marks + spatter
                float oil = clamp(pool*0.85 + drips*0.5, 0.0, 1.0);
                alb = mix(alb, float3(0.055,0.048,0.042), oil*0.80);             // grease darkens the deck
                alb = mix(alb, float3(0.035,0.032,0.030), slick*0.70);           // lubricant slick, darker still
                rough = mix(rough, 0.22, slick*0.85);                            // slicks read WET/glossy
                rough = clamp(rough + oil*0.10, 0.05, 1.0);                      // dried grease is duller
                metal = mix(metal, 0.12, slick*0.5);
            }
            float flood = C.water.x, dtime = C.amb.y;
            float wet = max(flood, liquid ? 1.0 : 0.0);                 // the lowest floor drowns (flood); pools always wet
            if(!liquid && fid == 7 && wet < 0.01){                      // floor-7 rock: water finds its way down → it POOLS
                float pf = rPuddleField(in.wp.xz + C.water.yz);
                float pool = rPuddleMask(pf);
                float damp = smoothstep(0.36, 0.50, pf) * (1.0 - pool);
                alb *= 1.0 - 0.22 * damp;                              // a damp soaked-in margin rings each pool
                wet = pool;
            }
            if(liquid){                                                // hazard pool — a live rippling glassy surface
                float2 q = in.wp.xz;
                float2 w1 = q*3.1 + float2(dtime*0.55, dtime*-0.41);
                float2 w2 = q*6.9 + float2(dtime*-0.33, dtime*0.49);
                float e = 0.09;
                float gx = (fbm(w1+float2(e,0))-fbm(w1-float2(e,0))) + 0.5*(fbm(w2+float2(e,0))-fbm(w2-float2(e,0)));
                float gz = (fbm(w1+float2(0,e))-fbm(w1-float2(0,e))) + 0.5*(fbm(w2+float2(0,e))-fbm(w2-float2(0,e)));
                N = normalize(N + float3(gx,0,gz)*2.4);                 // churning ripples from flowing noise
                if(fid == 3){ float pulse = fbm(q*1.6 + float2(dtime*0.5, dtime*0.37));
                    waterEmis += in.emis * (pulse - 0.5); }             // nukage: base·(0.5+pulse) via a delta on the always-added in.emis → an irregular pulse
                alb *= 0.55; rough = 0.10; metal = 0.0;                 // glassy hazard liquid
            } else if(wet > 0.01){                                      // standing water — the drowned deck / floor-7 pools
                float2 q = in.wp.xz;
                N = normalize(N + float3(cos(q.x*5.1 + dtime*1.1), 0.0, cos(q.y*4.7 - dtime*1.3)) * (0.14*wet));   // slow standing ripples
                alb = mix(alb, alb*float3(0.30,0.34,0.42), wet);        // water darkens + cools the bed under it
                rough = mix(rough, 0.08, wet); metal = 0.0;             // glazes the deck glossy
            }
        }

        float3 Vv=normalize(C.eye.xyz-in.wp); float ndv=max(dot(N,Vv),1e-3);
        float3 f0=mix(float3(0.04),alb,metal), diffCol=alb*(1-metal), col=float3(0);

        // ── wall/floor FIXTURES (sparse point lights) — unshadowed, player-independent ──
        int count=int(C.params.x);
        for(int i=0;i<count;i++){
            Light lp=lights[i]; float3 Ld=lp.posR.xyz-in.wp; float d2=dot(Ld,Ld);
            float dr2=d2*lp.posR.w; if(dr2>=1.0) continue;                 // outside the fixture's radius
            float dist=sqrt(max(d2,1e-6)); float3 L=Ld/dist;
            float ndl=max(dot(N,L),0.0); if(ndl<=0.0) continue;
            float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float atten=lp.colI.w * pow(1.0-dr2,2.0);                      // radius-bounded f·f falloff
            float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * lp.colI.rgb * (ndl*atten);
        }

        // ── analytic overhead ceiling-lamp GRID ──
        //  A pool's brightness derives ONLY from (lamp cell, surface) — there is NO player or view
        //  term, so it can never pop on move OR turn. Each fragment brackets its own 2×2 grid nodes
        //  (provably every lamp within the 2.7 m pool, since the 4 m spacing exceeds the radius),
        //  checks presence via the R8 mask (integer cell fetch, bounds-guarded), and lights from each
        //  real lamp at (cell+0.5, kLampY, cell+0.5). The nearest-3 shadow slices apply by EXACT cell
        //  match, gated to up-facing surfaces (a top-down ortho map is meaningless on a vertical wall).
        if(C.water.w > 0.5){                 // no ceiling-lamp grid on the plant floors (7–8) — bulkheads light those
            int shadowN=int(C.params.y+0.5);
            int mw=int(C.params.z), mh=int(C.params.w);
            int gx0=int(floor((in.wp.x-kGridOff)/kGridStep));
            int gz0=int(floor((in.wp.z-kGridOff)/kGridStep));
            float up=smoothstep(0.25,0.7,gn.y);
            float shx[3]={C.shX.x,C.shX.y,C.shX.z};
            float shz[3]={C.shZ.x,C.shZ.y,C.shZ.z};
            constexpr sampler maskPt(coord::normalized, address::clamp_to_edge, filter::nearest);   // exact cell (presence)
            constexpr sampler maskLin(coord::normalized, address::clamp_to_edge, filter::linear);    // interpolated (soft LOS)
            float2 mapSz=float2(mw,mh);
            for(int dz=0;dz<2;dz++){ for(int dx=0;dx<2;dx++){
                int gx=gx0+dx, gz=gz0+dz;
                int cx=kStride*gx+kPhase, cz=kStride*gz+kPhase;    // integer lamp cell = kStride·k + kPhase
                if(cx<0||cz<0||cx>=mw||cz>=mh) continue;           // map-edge guard BEFORE the fetch
                if(lampMask.sample(maskPt,(float2(cx,cz)+0.5)/mapSz).r < 0.75) continue; // 0 solid · 0.5 open · 1 lamp — need a real lamp
                float3 Lp=float3(float(cx)+0.5, kLampY, float(cz)+0.5);
                float3 Ld=Lp-in.wp; float d2=dot(Ld,Ld);
                float dr2=d2*kLampInvR2; if(dr2>=1.0) continue;    // outside the pool
                float dist=sqrt(max(d2,1e-6)); float3 L=Ld/dist;
                float ndl=max(dot(N,L),0.0); if(ndl<=0.0) continue;
                // SOFT line-of-sight: walk lamp→fragment sampling the presence mask BILINEARLY, and
                // accumulate a smooth transmittance (solid→0, open→1 over a ~1-cell ramp). This keeps a
                // pool from bleeding THROUGH a wall (the original leak) but with a diffused edge instead
                // of the grid-hard block — light still spreads freely across open cells + doorways.
                float vis=1.0;
                { float2 a=float2(float(cx)+0.5,float(cz)+0.5), b=in.wp.xz, e=b-a;
                  int ns=max(1,int(ceil(length(e)/0.35)));   // ~0.35 m steps
                  for(int s=1;s<ns;s++){ float2 pp=a+e*(float(s)/float(ns));
                      float m=lampMask.sample(maskLin, pp/mapSz).r;
                      vis=min(vis, smoothstep(0.12, 0.42, m)); }
                }
                if(vis<=0.001) continue;
                float sh=1.0;
                if(up>0.001){ for(int s=0;s<shadowN;s++){ if(cx==int(shx[s]) && cz==int(shz[s])){ sh=mix(1.0, pcfLamp(smap, uint(s), in.wp, C.lmvp[s]), up); break; } } }
                float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
                float atten=kLampInt * pow(1.0-dr2,2.0);
                float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
                col += (diffCol/3.14159265 + spec) * kLampCol * (ndl*atten*sh*vis);
            }}
        }

        // headlamp — the marine's helmet lamp (man-made), gated by headFwd.w (0 = off).
        if(C.headFwd.w > 0.001){
        { float3 toF=in.wp-C.eye.xyz; float dist=length(toF); float3 dir=toF/max(dist,1e-4);
          float cone=smoothstep(-0.15,0.55,dot(dir,C.headFwd.xyz));    // broad forward pool (lights the near floor/walls/ceiling)
          if(cone>0.0){ float3 L=-dir; float ndl=max(dot(N,L),0.0);
            float3 Hh=normalize(L+Vv); float ndh=max(dot(N,Hh),0.0), vdh=max(dot(Vv,Hh),0.0);
            float atten=C.headFwd.w*cone/(0.45+0.30*dist*dist);
            float3 spec=D_GGX(ndh,rough*rough)*G_Smith(ndv,ndl,rough)*F_Schlick(vdh,f0)/(4*ndv*ndl+1e-4);
            col += (diffCol/3.14159265 + spec) * float3(0.95,0.97,1.0) * (ndl*atten); } }
        // near-field spill — a little headlamp light always leaks around the marine
        // (short range), so no look direction leaves you blind on your own footing.
        { float3 Ld=C.eye.xyz-in.wp; float dn2=dot(Ld,Ld); float3 L=Ld*rsqrt(max(dn2,1e-6));
          float ndl=max(dot(N,L),0.0); float atten=0.9/(0.3+2.4*dn2);
          col += diffCol/3.14159265 * float3(0.90,0.93,1.0) * (ndl*atten); }
        }

        // ambient = the level's OWN fixtures propagated through the map (baked field) —
        // NO sourceless fill. Underground: unlit reaches fall to dark (intended).
        constexpr sampler ls(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 baked = field.sample(ls, in.wp.xz/float2(C.params.z, C.params.w)).rgb;
        float ao = clamp(0.55+0.45*grime, 0.35, 1.0);
        // AMBIENT. `baked` is a FLOOR-PLANE lookup, so applying it omnidirectionally hands every
        // surface the light arriving at the floor — including surfaces facing away from it. On world
        // geometry that is a fair approximation and it is what makes the levels read, so it stays.
        //
        // On the HELD WEAPON it is not fair at all: the barrel's top is a big flat face a few inches
        // from the camera, and lighting it with the floor put the deck on top of the gun — brightest
        // over a bright floor, which is exactly backwards. Weighting the specular by the reflection
        // vector (see kEnvCeil below) fixed the sharp Fresnel band along the upper edge but left THIS
        // term untouched, so the wash remained and a grated deck still read on the barrel.
        //
        // For the viewmodel, weight it hemispherically: a downward-facing face sees the floor in
        // full, an upward-facing one sees the ceiling, which away from the lamps is dark concrete.
        float ambDir = 1.0;
        if (C.amb.z > 0.5) ambDir = mix(1.0, kEnvCeil, smoothstep(-0.15, 0.65, N.y));
        col += baked * C.amb.w * alb * ao * ambDir;
        // env-ish spec off the baked field. The field is a FLOOR-PLANE lookup — the light arriving at
        // this map cell — so it is only a plausible reflection for rays heading DOWN. Applied without
        // regard to direction it put the floor on TOP of the gun barrel, which is the one place the
        // floor cannot be; the grazing-angle Fresnel term made it a bright band exactly along the
        // upper edge. Weight it by the reflection vector instead: the full field below the horizon, a
        // dim fraction above it, since Citadel's ceilings are dark concrete away from the lamps.
        float3 Rv = reflect(-Vv, N);
        float3 envSpec = baked * mix(1.0, kEnvCeil, smoothstep(-0.05, 0.55, Rv.y));
        col += f0 * envSpec * 0.6 * pow(1.0-ndv,3.0) * (1.0-rough);
        // textured walls carry their emission via the texture (wemis/wallGlow), so drop the flat-material
        // emissive there (it was a uniform amber wash washing the CRT blacks out).
        float3 baseEmis = (in.tid >= 0.0) ? float3(0.0) : in.emis;
        float3 emisTerm = baseEmis + decalEmis + waterEmis + alb * wemis + wallGlow;  // self-lit fixtures + decals + textured-wall glow (CRT/panel) + CRT content
        col += emisTerm;
        // ── THE POWER SAG ── a distant fault drags the whole grid down for ~1.7 s: the lamps, the lit
        // panels and the display walls all droop and flicker together (World.powerDim). It rides the
        // EMISSIVE as well as the lit surfaces on purpose — a brownout that left the CRTs burning at
        // full would read as a lighting effect rather than as the colony losing power.
        //
        // This was live under the raymarcher and went dark with it: the kernel read the value from its
        // own debug uniform and nothing replaced that when the rasteriser took over, so the sim has
        // been computing a dropout every ~25-60 s that nothing has drawn since the pivot.
        col *= 1.0 - clamp(C.shX.w, 0.0, 0.9);
        // LINEAR HDR out; alpha = EMISSION MASK so only emitters bloom (never merely bright-lit walls).
        // The whole frame is bloomed, then ACES-graded, gamma-corrected and vignetted ONCE in composite_frag.
        float emL = dot(emisTerm, float3(0.299, 0.587, 0.114));
        // C.amb.z>0.5 = the first-person VIEWMODEL pass: force perp NEGATIVE so it is always nearest — mesh
        // creatures never composite over the gun (#15), and the composite skips bloom over it (#14, stays opaque).
        RROut o; o.color=float4(max(col, 0.0), min(emL, 1.0));
        o.perp = (C.amb.z > 0.5) ? -1.0 : dot(in.wp - C.eye.xyz, C.camFwd.xyz);
        return o;
    }
    """

    // ════════════════════════════════════════════════════════════════════════
    //  VOLUMETRIC FIRE + BLOOM — the raster path runs the SAME fire the raymarcher
    //  marches (fireEmission: 3-D turbulence puffs, blackbody temperature, absorbing
    //  smoke), as a full-screen pass: reconstruct the view ray, take tmax from the
    //  world's perp-depth so walls occlude it, composite bg·transmittance + emission
    //  into an HDR target, then bright-pass → blur → additive composite so the
    //  white-hot cores BLOOM (the LDR frame has no HDR of its own). Same code as the
    //  GPU → same look.
    static let fireSrc = """
    #include <metal_stdlib>
    using namespace metal;

    struct FireEmitter { float4 p0, p1, p2; };
    struct FireU { float4x4 invVP; float4 eye; float4 camFwd; float4 misc; };   // eye.w=time · camFwd.w=ceilH · misc=(count,W,H,0)
    struct Fx { float4 a; float4 b; float4 c; };                                // blur: a=(dirX,dirY,W,H) · composite: a=(bloomGain,0,W,H) · b=(dofStrength,dofFocus,flare,dofRange) · c=(flareNearFade,0,0,0)
    struct FSOut { float4 clip [[position]]; };

    // ── ported verbatim from GPURaymarch (the raymarcher's fire) ──
    static inline float f_hash13(float3 p){ p=fract(p*0.1031); p+=dot(p,p.zyx+31.32); return fract((p.x+p.y)*p.z); }
    static inline float f_vnoise3(float3 p){
        float3 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        float a=f_hash13(i+float3(0,0,0)), b=f_hash13(i+float3(1,0,0));
        float c=f_hash13(i+float3(0,1,0)), d=f_hash13(i+float3(1,1,0));
        float e=f_hash13(i+float3(0,0,1)), g=f_hash13(i+float3(1,0,1));
        float h=f_hash13(i+float3(0,1,1)), k=f_hash13(i+float3(1,1,1));
        return mix(mix(mix(a,b,f.x),mix(c,d,f.x),f.y), mix(mix(e,g,f.x),mix(h,k,f.x),f.y), f.z);
    }
    static inline float f_fbm3(float3 p){ float s=0.0,a=0.5; for(int i=0;i<3;i++){ s+=a*f_vnoise3(p); p*=2.02; a*=0.5; } return s; }
    static inline float3 f_blackbody(float T){ T=clamp(T,0.0,1.0); return float3(1.90*T, 1.15*T*T*T, 0.35*T*T*T*T*T); }

    static inline float3 fireEmission(float3 ro, float3 rd, float tmax, float ceilH,
                                      constant FireEmitter* F, int n, float time, thread float& bgTransOut) {
        float3 acc = float3(0.0);
        float bgTrans = 1.0;
        for (int i = 0; i < n; i++) {
            float3 base = F[i].p0.xyz;  float baseR = F[i].p0.w;
            float3 flow = F[i].p1.xyz;  float len   = F[i].p1.w;
            float vigor = F[i].p2.x;    float seed  = F[i].p2.y;
            bool  jet   = F[i].p2.z > 0.5;  float smokeBias = F[i].p2.w;
            float3 bc = base + flow * (len * 0.5);
            float  bR = len * 0.6 + baseR * 2.4 + 0.35;
            float3 oc = ro - bc; float bq = dot(oc, rd);
            if (bq * bq - (dot(oc, oc) - bR * bR) <= 0.0) continue;
            float3 up = fabs(flow.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
            float3 e1 = normalize(cross(flow, up));
            float3 e2 = cross(flow, e1);
            float fk    = 0.80 + 0.14 * sin(time * 11.0 + seed * 6.3) + 0.10 * sin(time * 27.0 + seed * 15.1);
            float opac  = clamp(vigor * 0.60, 0.38, 1.0);
            float bright= clamp(vigor * 0.85, 0.30, 1.6) * fk;
            int   NP    = jet ? 8 : 10;
            float rate  = jet ? 2.2 : 0.9;
            float drift = fract(time * rate);
            float scr   = jet ? 3.2 : 1.7;
            float trans = 1.0;
            float3 localAcc = float3(0.0);
            for (int k = 0; k < NP; k++) {
                float age  = (float(k) + drift) / float(NP);
                float fade = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.86, 1.0, age));
                if (fade < 0.02) continue;
                float ph  = seed * 6.3 + float(k) * 1.7;
                float wob = baseR * (jet ? 0.35 : 0.85) * (0.35 + 1.9 * age);
                float wa  = sin(age * 5.1 + ph)       + 0.5 * sin(age * 11.7 + ph * 1.7);
                float wb  = cos(age * 4.3 + ph * 1.3) + 0.5 * sin(age *  9.3 + ph * 0.7);
                float3 C  = base + flow * (age * len) + (e1 * wa + e2 * wb) * (wob * 0.5);
                if (!jet) C.y = min(C.y, ceilH - 0.05);
                float R = jet ? baseR * (0.16 + 1.05 * age) : baseR * (0.45 + 0.75 * age);
                float3 rel = ro - C;
                float b2 = dot(rel, rd);
                float c2 = dot(rel, rel) - R * R;
                float disc = b2 * b2 - c2;
                if (disc <= 0.0) continue;
                float sq = sqrt(disc);
                float t0 = max(0.0, -b2 - sq);
                float t1 = min(tmax, -b2 + sq);
                if (t1 <= t0) continue;
                float thick = (t1 - t0) / (2.0 * R);
                float3 sp   = (ro + rd * t0) * 7.0 - flow * (time * scr) + seed * 11.0;
                float  turb = f_fbm3(sp);
                float dens = smoothstep(0.05, 0.42, thick - (0.72 - turb) * 0.60) * fade;
                if (dens < 0.004) continue;
                float axial = jet ? (1.0 - 0.65 * age) : (smoothstep(0.0, 0.16, age) * (1.0 - 0.75 * age));
                float heat  = clamp(axial * (0.35 + 0.85 * turb) * (0.50 + 0.65 * thick), 0.0, 1.0);
                float smokeF= smoothstep(0.42 - 0.14 * smokeBias, 0.88, age);
                float flameA= dens * opac * (1.0 - smokeF);
                float smokeA= dens * (0.55 + 0.40 * smokeBias) * smokeF;
                float3 emis     = f_blackbody(heat) * bright;
                float3 smokeCol = mix(float3(0.05,0.035,0.028), float3(0.012,0.012,0.013), smokeF);
                localAcc += emis * (flameA * trans) + smokeCol * (smokeA * trans);
                trans    *= (1.0 - flameA) * (1.0 - smokeA);
                if (trans < 0.02) break;
            }
            acc += localAcc * bgTrans;
            bgTrans *= trans;
        }
        bgTransOut = bgTrans;
        return acc * 2.0;
    }

    vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        FSOut o; o.clip = float4(p[vid], 0, 1); return o;
    }

    // FIRE → HDR (bg·transmittance + emission)
    fragment float4 fire_frag(FSOut in [[stage_in]],
                              constant FireU& U [[buffer(0)]],
                              constant FireEmitter* F [[buffer(1)]],
                              texture2d<float> bgTex [[texture(0)]],
                              texture2d<float> perpTex [[texture(1)]]) {
        float2 uv = in.clip.xy / U.misc.yz;                               // pixel → 0..1 (top-left origin)
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);          // Metal NDC: +Y up
        float4 wf = U.invVP * float4(ndc, 1.0, 1.0); wf /= wf.w;          // far-plane world point
        float3 ro = U.eye.xyz;
        float3 rd = normalize(wf.xyz - ro);
        float perp = perpTex.sample(s, uv).r;
        float denom = max(1e-3, dot(rd, U.camFwd.xyz));
        float tmax = perp >= 1e8 ? 1e8 : perp / denom;                   // perp-depth → ray distance
        float4 bg = bgTex.sample(s, uv);
        float bgTrans;
        float3 emis = fireEmission(ro, rd, tmax, U.camFwd.w, F, int(U.misc.x), U.eye.w, bgTrans);
        float emL = dot(emis, float3(0.299, 0.587, 0.114));                  // fire cores glow
        return float4(bg.rgb * bgTrans + emis, max(bg.a * bgTrans, min(emL, 1.0)));   // preserve world emission mask under the flame
    }

    // BRIGHT-PASS — bloom the EMITTERS only, via the emission mask in alpha (fixtures, plasma cells, LEDs,
    // lit screens, fire cores). A bright-LIT wall has alpha 0 and never blooms — no headlamp white-out.
    fragment float4 bright_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]],
                                texture2d<float> src [[texture(0)]], texture2d<float> perp [[texture(1)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = src.sample(s, uv);
        float3 b = c.rgb * clamp(c.a, 0.0, 1.0);
        // ── WHOSE BLOOM IS THIS? ── alpha carries the share of this pixel's bright energy that came from
        // the HELD WEAPON (perp < 0 marks it). The blur is linear, so after blurring, alpha still holds
        // the gun's contribution to whatever landed on each pixel, and the composite can honour the two
        // origins differently instead of masking their sum.
        //
        // This is what lets the gun be genuinely emissive without giving up the mask. The mask exists to
        // stop a lamp BEHIND the gun haloing across its silhouette and making it read as semi-transparent
        // — a real problem, and one that has nothing to do with the gun's own LEDs, cell window, pilot
        // flame or muzzle flash, which were being suppressed purely for sharing the same pixels.
        float vm = perp.sample(s, uv).r < 0.0 ? dot(b, float3(0.299, 0.587, 0.114)) : 0.0;
        return float4(b, vm);
    }

    // separable Gaussian blur (a.xy = texel step)
    fragment float4 blur_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float w[5] = { 0.227027, 0.194595, 0.121622, 0.054054, 0.016216 };
        // FOUR channels, not three: alpha carries the viewmodel's share of the bright energy (see
        // bright_frag) and has to survive the blur alongside the colour it belongs to.
        float4 acc = src.sample(s, uv) * w[0];
        for (int i = 1; i < 5; i++) {
            acc += src.sample(s, uv + X.a.xy * float(i)) * w[i];
            acc += src.sample(s, uv - X.a.xy * float(i)) * w[i];
        }
        return acc;
    }

    // FINAL TONEMAP — HDR frame + bloom → the headlamp grade (dim + warm/cool luma tint), ACES filmic
    // tonemap, gamma and vignette, all applied ONCE to the whole composited frame → 8-bit. (X.a.x = bloom gain.)
    fragment float4 composite_frag(FSOut in [[stage_in]], constant Fx& X [[buffer(0)]],
                                   texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                   texture2d<float> perp [[texture(2)]], texture2d<float> dof [[texture(3)]]) {
        float2 uv = in.clip.xy / X.a.zw;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // ── BLOOM, BY ORIGIN ── the WORLD's bloom is still kept off the gun (perp < 0), because a lamp
        // behind it haloing across its silhouette makes the gun read as semi-transparent. The GUN's OWN
        // bloom is allowed everywhere, so its LEDs, cell window, pilot flame and muzzle flash finally
        // glow — they have always been emissive, and were suppressed only for sharing the gun's pixels.
        // alpha is the gun's share of the blurred energy (bright_frag), so the two are separated by
        // ORIGIN rather than by a mask over their sum, and it costs no extra pass.
        float4 bl = bloom.sample(s, uv);
        float bLum = dot(bl.rgb, float3(0.299, 0.587, 0.114));
        float vmShare = clamp(bl.a / max(bLum, 1e-4), 0.0, 1.0);
        float worldMask = perp.sample(s, uv).r < 0.0 ? 0.0 : 1.0;

        // ── DEPTH OF FIELD (X.b.x = strength, .y = focus distance, .w = range) ──
        // Mixed in LINEAR HDR, before the grade, because that is where defocus
        // physically happens: blur after the tonemap smears the *grade* instead of
        // the light, and bright highlights stop blooming into their neighbours the
        // way an out-of-focus lamp actually does.
        float3 scene = hdr.sample(s, uv).rgb;
        if (X.b.x > 0.0) {
            float d = perp.sample(s, uv).r;
            // The held weapon (perp < 0) is NEVER defocused. It is inches from the eye,
            // it is the one thing on screen that must stay readable, and softening it
            // reads instantly as a broken frame rather than as an effect.
            if (d >= 0.0) {
                float coc = clamp(abs(d - X.b.y) / max(X.b.w, 1e-3), 0.0, 1.0);
                scene = mix(scene, dof.sample(s, uv).rgb, coc * X.b.x);
            }
        }

        float3 c = scene + X.a.x * bl.rgb * mix(worldMask, 1.0, vmShare);

        // ── LENS FLARE (X.b.z = strength) ── the VISOR, not a camera. Citadel has no
        // camera, but it does have glass in front of the player's eye, and this is what
        // a bright source does to glass.
        //
        // It rides the bloom texture, which the bright pass has already reduced to
        // emissive energy only — so the flare costs no new pass and no new mask.
        //
        // **Threshold 1.0 is not a tuning value.** In linear HDR, 1.0 is displayable
        // white; everything above it is what the ACES curve is compressing back into
        // range. Taking only that excess means flare comes from sources genuinely
        // brighter than white — fire, the plant, a lamp looked at directly — and is
        // absent the rest of the time. That is what makes it *occasional* without a
        // timer or a random number anywhere near it.
        if (X.b.z > 0.0) {
            float2 cc = uv - 0.5;
            float3 f = float3(0.0);
            float wsum = 0.0;

            // **Every tap is WEIGHTED AND AVERAGED, never summed.** The first version
            // added thirteen taps together, so the flare contributed roughly an order of
            // magnitude more light than the source it came from: the ghosts landed as
            // opaque blobs and the streak washed the whole frame red, lifting walls,
            // floor and HUD into a haze. A flare redistributes a source's light — it
            // cannot add more than the source has — so the normalisation is not a
            // taste knob, it is the physics.
            //
            // **No ghosts.** Mirrored ghosts were tried and removed. The only bright
            // source available here is the *blurred* bloom, so mirroring it through the
            // optical centre can produce nothing but a big soft blob — which is exactly
            // how it read: two yellow crescents hanging in the ceiling, obviously wrong
            // at any strength, and the one part of the effect that was clearly visible.
            // Real ghosts need a small point source, which means isolating bright peaks
            // in a pass of their own. That is a different feature, not a tuning problem,
            // so the machinery came out rather than getting another coat of paint.
            //
            // **Sampled off the HDR frame, not the bloom.** The bloom was the obvious
            // input and it was the wrong one: it is already blurred, so smearing it
            // horizontally produced a marginally wider soft blob and nothing that read
            // as a streak. A streak needs a small, SHARP, bright core to smear, which is
            // what the unblurred HDR frame has.
            //
            // Masked by `a`, which is the same emissive mask `bright_frag` uses — so the
            // flare fires on the things the game itself calls glowing (fire cores, lamp
            // filaments, plasma, the plant) and never on a merely well-lit wall. Reusing
            // that definition rather than inventing a second one is the point.
            // **The WORLD flares; the held weapon does not.** The gun's own LEDs are the
            // brightest small emissives on screen and they sit at the bottom of the frame,
            // so letting them streak painted blue wings straight across the translucent
            // HUD panel — HEALTH and ARMOUR with light smeared over them, which reads as
            // a rendering fault rather than an optic. `perp < 0` already marks viewmodel
            // pixels, and this renderer already keeps the world's bloom off the gun for
            // the same class of reason, so the distinction is one this frame already knows
            // how to make.
            for (int i = 1; i <= 5; i++) {
                float o = float(i) * 0.009;
                float w = 1.0 - float(i) / 6.0;
                float2 up = uv + float2(o, 0.0), um = uv - float2(o, 0.0);
                float4 hp = hdr.sample(s, up);
                float4 hm = hdr.sample(s, um);
                float dp = perp.sample(s, up).r, dm = perp.sample(s, um).r;
                // **Fades with proximity, and this is a derivation not a fudge.** The
                // streak is a fixed fraction of frame width — a property of the optic, as
                // it is in reality — while a source's apparent size goes as 1/depth. So
                // the ratio of streak length to source size is proportional to depth: a
                // distant lamp is a point and the streak dwarfs it, which reads as light;
                // a fire two metres away is larger on screen than the whole streak, so the
                // same smear can only push its edges sideways. That looked like a smudge
                // rather than light, which is exactly how it was described.
                //
                // `d/(d+d0)` saturates: far sources keep full strength, near ones fall off
                // smoothly, and there is no distance at which it switches on with a snap.
                float ap = dp / (dp + X.c.x), am = dm / (dm + X.c.x);
                float3 ep = max(hp.rgb * clamp(hp.a, 0.0, 1.0) - 1.0, 0.0) * step(0.0, dp) * ap;
                float3 em = max(hm.rgb * clamp(hm.a, 0.0, 1.0) - 1.0, 0.0) * step(0.0, dm) * am;
                f += (ep + em) * w * float3(0.60, 0.75, 1.00);
                wsum += w * 2.0;
            }
            f /= max(wsum, 1e-4);

            // Weakest at the edges: a visor flares most when you are looking INTO the
            // source, and the vignette below would fight a bright rim anyway.
            f *= 1.0 - 0.5 * clamp(dot(cc, cc) * 2.0, 0.0, 1.0);
            c += f * X.b.z;
        }

        c *= 0.9;                                                             // headlamp dim
        float lum = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(c * float3(0.84, 0.96, 1.16), c * float3(1.14, 1.0, 0.80), clamp(lum, 0.0, 1.0));   // cool shadows, warm highs
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);         // ACES filmic
        c = pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2));                       // gamma
        float2 dd = uv * 2.0 - 1.0; c *= 1.0 - 0.20 * dot(dd, dd);            // vignette
        return float4(c, 1.0);
    }
    """

    // ── particle billboards ───────────────────────────────────────────────────
    // The quads arrive already projected (see buildParticles), so this stage only culls, shades the
    // radial profile and blends. Output is PREMULTIPLIED: alpha 0 = pure addition (flame, sparks),
    // alpha = coverage = ordinary alpha blending (smoke, steam).
    static let particleSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct SV { float2 clip; float2 local; float4 rgba; float4 misc; };
    struct SO { float4 pos [[position]]; float2 local; float4 rgba; float mode; };

    vertex SO spr_vertex(uint vid [[vertex_id]],
                         const device SV* v [[buffer(0)]],
                         texture2d<float> scenePerp [[texture(0)]]) {
        SV s = v[vid];
        SO o;
        o.local = s.local; o.rgba = s.rgba; o.mode = s.misc.w;
        // Whole-sprite occlusion, from ONE sample at the sprite's centre — the same test the CPU
        // compositor made, so a spark behind a sealed door stays hidden. Doing it here rather than
        // per fragment means an occluded sprite costs six vertex invocations and no shading at all:
        // collapse it to a point outside the clip volume and the rasteriser drops it.
        if (s.misc.z >= scenePerp.read(uint2(s.misc.xy)).r) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }
        o.pos = float4(s.clip, 0.0, 1.0);
        return o;
    }

    fragment float4 spr_frag(SO in [[stage_in]]) {
        if (in.mode > 1.5) {
            // SPARK — a sharp glint with a comet streak trailing UP through its arc. `local` is in
            // PIXELS here: the CPU path drew a 1px core plus six fading pixels above it, which is
            // one analytic taper. −y is up.
            float q = length(in.local);
            float core = smoothstep(1.7, 0.0, q);
            float tail = (in.local.y < 0.0 && abs(in.local.x) < 0.9) ? max(0.0, 1.0 + in.local.y / 7.0) : 0.0;
            float a = in.rgba.a * max(core, tail);
            return float4(in.rgba.rgb * a, 0.0);                       // additive
        }
        // SOFT ORB — the CPU path's falloff table was (1 − sqrt(d²/r²))², i.e. (1 − d/r)² exactly;
        // evaluated here instead of read from a 257-entry LUT, so it is the same curve without the
        // quantisation. Radial cutoff keeps the quad's corners out of the blend.
        float q = length(in.local);
        if (q > 1.0) discard_fragment();
        float f = 1.0 - q; f *= f;
        float a = in.rgba.a * f;
        return float4(in.rgba.rgb * a, in.mode > 0.5 ? 0.0 : a);       // 1 = additive flame · 0 = alpha smoke
    }
    """
}
