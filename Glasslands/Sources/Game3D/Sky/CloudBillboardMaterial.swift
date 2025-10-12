//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Volumetric billboard impostor via a fragment-only SceneKit shader modifier.
//  No SCNProgram, no geometry modifier, and no function/lambda definitions.
//  Each quad integrates vapour in a thin world-space slab around its plane.
//

import SceneKit
import UIKit
import simd

enum CloudBillboardMaterial {

    private static var registry = NSHashTable<SCNMaterial>.weakObjects()
    static let volumetricMarker = "/* VAPOUR_IMPOSTOR_SM_V3 */"

    // Fragment-only shader modifier. Everything is inline inside #pragma body.
    private static let fragSM: String =
    """
    #pragma transparent

    #pragma arguments
    // Per-frame (pushed from VolCloudUniformsStore via syncFromVolStore)
    float  u_time;
    float2 u_wind;          // world wind (x,z)
    float2 u_domainOff;     // large-scale advection offset
    float  u_domainRot;     // radians
    float  u_coverage;      // 0..1
    float  u_densityMul;    // thickness multiplier
    float  u_stepMul;       // 0.60..1.35
    float  u_detailMul;     // erosion strength
    float  u_puffScale;     // micro puffs frequency
    float  u_puffStrength;  // micro puffs weight
    float  u_macroScale;    // island mask frequency
    float  u_macroThreshold;// island mask threshold [0,1]
    float  u_horizonLift;   // subtle vertical lift
    float3 u_sunDir;        // world sun dir (normalized)
    // Per-material: world half-thickness of the slab for this quad
    float  u_slabHalf;

    #pragma body
    // === Setup ===
    float3 P0_world = _surface.position;          // world position of this fragment on the quad
    float3 N        = normalize(_surface.normal); // world normal of the quad
    float2 uv01     = _surface.diffuseTexcoord;   // 0..1
    float2 uv       = uv01 * 2.0 - 1.0;           // -1..1

    // De-emphasise hard quad edges
    float edgeMask = smoothstep(1.0, 0.92, 1.0 - length(uv));

    // Integrate along the quad normal (no camera matrices needed)
    float tEnt = -u_slabHalf;
    float tExt =  u_slabHalf;
    float Lm   = tExt - tEnt;
    if (Lm <= 1e-5) { discard_fragment(); }

    // Steps with distance LOD
    float distLOD   = clamp(Lm / 2500.0, 0.0, 1.2);
    float stepMul   = clamp(u_stepMul, 0.60, 1.35);
    int   baseSteps = int(round(mix(10.0, 18.0, 1.0 - distLOD*0.7)));
    int   numSteps  = clamp(int(round(float(baseSteps) * stepMul)), 8, 24);
    float dt        = Lm / float(numSteps);

    // Jitter
    float j = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    float t = tEnt + (0.25 + 0.5*j) * dt;

    // Precompute rotation (shared by density sampling)
    float ca = cos(u_domainRot), sa = sin(u_domainRot);

    // Sun lighting (approximate — use surface normal since we don't build V here)
    float mu = clamp(dot(N, normalize(u_sunDir)), -1.0, 1.0);
    float g  = 0.60;
    float g2 = g*g;
    float phaseHG = (1.0 - g2) / max(1e-4, 4.0*3.14159265358979323846*pow(1.0 + g2 - 2.0*g*mu, 1.5));

    half T = half(1.0);                 // transmittance
    const half refineMul = half(0.45);  // local refinement
    const int  refineMax = 2;

    for (int i = 0; i < numSteps && T > half(0.004); ++i) {
        float3 sp = P0_world + N * t; // sample point in world

        // === densityAt(sp) — all inline ===
        // Altitude profile (400..1400m default slab)
        float baseY = 400.0;
        float topY  = 1400.0;
        float h = clamp((sp.y - baseY) / max(1.0, (topY - baseY)), 0.0, 1.0);
        float up = smoothstep(0.03, 0.25, h);
        float dn = 1.0 - smoothstep(0.68, 1.00, h);
        float h01 = pow(clamp(up * dn, 0.0, 1.0), 0.80);

        // Domain (rotate + offset) and vertical-aware advection
        float2 xz  = sp.xz + u_domainOff;
        float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);
        float adv  = mix(0.55, 1.55, h01);
        float2 advXY = xzr + u_wind * adv * (u_time * 0.0035);

        // Macro islands (low-frequency Worley) → scattered cumulus
        float2 wm = advXY * u_macroScale;
        float2 wi = floor(wm);
        float2 wf = wm - wi;
        float dMacro = 1e9;
        for (int yy = -1; yy <= 1; ++yy) {
            for (int xx = -1; xx <= 1; ++xx) {
                float2 gcell = float2(xx, yy);
                float  rx = fract(sin(dot(wi + gcell, float2(127.1,311.7))) * 43758.5453123);
                float  ry = fract(sin(dot(wi + gcell, float2(269.5,183.3))) * 43758.5453123);
                float2 o  = float2(rx, ry);
                float2 r  = gcell + o - wf;
                dMacro = min(dMacro, dot(r, r));
            }
        }
        float macro = 1.0 - clamp(sqrt(max(dMacro, 0.0)), 0.0, 1.0);
        float macroMask = smoothstep(u_macroThreshold - 0.10, u_macroThreshold + 0.10, macro);

        // 3D fbm base (two octaves of value noise)
        float3 Pfbm = float3(advXY.x, sp.y, advXY.y) * 0.00110;

        // octave 1
        float3 p1 = floor(Pfbm);
        float3 f1 = Pfbm - p1; f1 = f1*f1*(3.0 - 2.0*f1);
        const float3 OFF = float3(1.0, 57.0, 113.0);
        float n1 = dot(p1, OFF);
        float n1_000 = fract(sin(n1 + 0.0  ) * 43758.5453123);
        float n1_100 = fract(sin(n1 + 1.0  ) * 43758.5453123);
        float n1_010 = fract(sin(n1 + 57.0 ) * 43758.5453123);
        float n1_110 = fract(sin(n1 + 58.0 ) * 43758.5453123);
        float n1_001 = fract(sin(n1 + 113.0) * 43758.5453123);
        float n1_101 = fract(sin(n1 + 114.0) * 43758.5453123);
        float n1_011 = fract(sin(n1 + 170.0) * 43758.5453123);
        float n1_111 = fract(sin(n1 + 171.0) * 43758.5453123);
        float nx1_00 = mix(n1_000, n1_100, f1.x);
        float nx1_10 = mix(n1_010, n1_110, f1.x);
        float nx1_01 = mix(n1_001, n1_101, f1.x);
        float nx1_11 = mix(n1_011, n1_111, f1.x);
        float nxy1_0 = mix(nx1_00, nx1_10, f1.y);
        float nxy1_1 = mix(nx1_01, nx1_11, f1.y);
        float fbm1   = mix(nxy1_0, nxy1_1, f1.z);

        // octave 2
        float3 Pfbm2 = Pfbm * 2.02 + 19.19;
        float3 p2 = floor(Pfbm2);
        float3 f2 = Pfbm2 - p2; f2 = f2*f2*(3.0 - 2.0*f2);
        float n2 = dot(p2, OFF);
        float n2_000 = fract(sin(n2 + 0.0  ) * 43758.5453123);
        float n2_100 = fract(sin(n2 + 1.0  ) * 43758.5453123);
        float n2_010 = fract(sin(n2 + 57.0 ) * 43758.5453123);
        float n2_110 = fract(sin(n2 + 58.0 ) * 43758.5453123);
        float n2_001 = fract(sin(n2 + 113.0) * 43758.5453123);
        float n2_101 = fract(sin(n2 + 114.0) * 43758.5453123);
        float n2_011 = fract(sin(n2 + 170.0) * 43758.5453123);
        float n2_111 = fract(sin(n2 + 171.0) * 43758.5453123);
        float nx2_00 = mix(n2_000, n2_100, f2.x);
        float nx2_10 = mix(n2_010, n2_110, f2.x);
        float nx2_01 = mix(n2_001, n2_101, f2.x);
        float nx2_11 = mix(n2_011, n2_111, f2.x);
        float nxy2_0 = mix(nx2_00, nx2_10, f2.y);
        float nxy2_1 = mix(nx2_01, nx2_11, f2.y);
        float fbm2   = mix(nxy2_0, nxy2_1, f2.z);

        float base = 0.5*fbm1 + 0.25*fbm2;

        // Micro puffs (two-octave inverted Worley)
        float  yy  = sp.y * 0.002 + 5.37;
        float2 ap0 = advXY * u_puffScale + float2(yy, -yy*0.7);
        float2 ai0 = floor(ap0), af0 = ap0 - ai0;
        float d0 = 1e9;
        for (int y0=-1; y0<=1; ++y0){
            for (int x0=-1; x0<=1; ++x0){
                float2 g = float2(x0,y0);
                float rx = fract(sin(dot(ai0+g, float2(127.1,311.7))) * 43758.5453123);
                float ry = fract(sin(dot(ai0+g, float2(269.5,183.3))) * 43758.5453123);
                float2 o = float2(rx, ry);
                float2 r = g + o - af0;
                d0 = min(d0, dot(r,r));
            }
        }
        float w0 = 1.0 - clamp(sqrt(max(d0,0.0)), 0.0, 1.0);

        float2 ap1 = advXY * (u_puffScale * 2.03) + float2(yy*1.3, yy*0.5);
        float2 ai1 = floor(ap1), af1 = ap1 - ai1;
        float d1 = 1e9;
        for (int y1=-1; y1<=1; ++y1){
            for (int x1=-1; x1<=1; ++x1){
                float2 g = float2(x1,y1);
                float rx = fract(sin(dot(ai1+g, float2(127.1,311.7))) * 43758.5453123);
                float ry = fract(sin(dot(ai1+g, float2(269.5,183.3))) * 43758.5453123);
                float2 o = float2(rx, ry);
                float2 r = g + o - af1;
                d1 = min(d1, dot(r,r));
            }
        }
        float w1    = 1.0 - clamp(sqrt(max(d1,0.0)), 0.0, 1.0);
        float puffs = clamp(0.6*w0 + 0.33*w1, 0.0, 1.0);

        float3 P_ero = float3(advXY.x, sp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
        float3 pe = floor(P_ero);
        float3 fe = P_ero - pe; fe = fe*fe*(3.0 - 2.0*fe);
        float ne = dot(pe, OFF);
        float e000 = fract(sin(ne + 0.0  ) * 43758.5453123);
        float e100 = fract(sin(ne + 1.0  ) * 43758.5453123);
        float e010 = fract(sin(ne + 57.0 ) * 43758.5453123);
        float e110 = fract(sin(ne + 58.0 ) * 43758.5453123);
        float e001 = fract(sin(ne + 113.0) * 43758.5453123);
        float e101 = fract(sin(ne + 114.0) * 43758.5453123);
        float e011 = fract(sin(ne + 170.0) * 43758.5453123);
        float e111 = fract(sin(ne + 171.0) * 43758.5453123);
        float ex00 = mix(e000, e100, fe.x);
        float ex10 = mix(e010, e110, fe.x);
        float ex01 = mix(e001, e101, fe.x);
        float ex11 = mix(e011, e111, fe.x);
        float exy0 = mix(ex00, ex10, fe.y);
        float exy1 = mix(ex01, ex11, fe.y);
        float erode = mix(exy0, exy1, fe.z);

        float shape = base + u_puffStrength*(puffs - 0.5)
                    - (1.0 - erode) * (0.30 * u_detailMul);

        float coverInv = 1.0 - u_coverage;
        float thLo     = clamp(coverInv - 0.20, 0.0, 1.0);
        float thHi     = clamp(coverInv + 0.28, 0.0, 1.2);
        float gate     = smoothstep(thLo, thHi, shape);
        float dens     = pow(clamp(gate, 0.0, 1.0), 0.85);

        dens *= macroMask;
        // tiny vertical lift
        {
            float yp = sp.y + u_horizonLift*120.0;
            float hp = clamp((yp-baseY)/max(1.0,(topY-baseY)), 0.0, 1.0);
            float hpu = smoothstep(0.03, 0.25, hp);
            float hpd = 1.0 - smoothstep(0.68, 1.00, hp);
            dens *= pow(clamp(hpu*hpd, 0.0, 1.0), 0.80);
        }

        half rho = half(dens) * half(edgeMask);
        if (rho < half(0.0025)) { t += dt; continue; }

        // One-tap sun probe folded into extinction
        {
            float dL = 200.0;
            float3 lpSun = sp + normalize(u_sunDir) * dL;
            // Re-sample dens at lpSun (copy of key parts; light cost)
            float2 xz2  = lpSun.xz + u_domainOff;
            float2 xzr2 = float2(xz2.x*ca - xz2.y*sa, xz2.x*sa + xz2.y*ca);
            float  adv2 = mix(0.55, 1.55,
                              pow(clamp((lpSun.y-baseY)/max(1.0,(topY-baseY)),0.0,1.0), 1.0));
            float2 advXY2 = xzr2 + u_wind * adv2 * (u_time * 0.0035);
            float2 wm2 = advXY2 * u_macroScale;
            float2 wi2 = floor(wm2), wf2 = wm2 - wi2;
            float dM2 = 1e9;
            for (int yy2=-1; yy2<=1; ++yy2){
                for (int xx2=-1; xx2<=1; ++xx2){
                    float2 g2c = float2(xx2,yy2);
                    float rx2 = fract(sin(dot(wi2+g2c, float2(127.1,311.7))) * 43758.5453123);
                    float ry2 = fract(sin(dot(wi2+g2c, float2(269.5,183.3))) * 43758.5453123);
                    float2 o2 = float2(rx2, ry2);
                    float2 r2 = g2c + o2 - wf2;
                    dM2 = min(dM2, dot(r2,r2));
                }
            }
            float macro2 = 1.0 - clamp(sqrt(max(dM2,0.0)), 0.0, 1.0);
            float macroMask2 = smoothstep(u_macroThreshold - 0.10, u_macroThreshold + 0.10, macro2);

            float3 PfbmS = float3(advXY2.x, lpSun.y, advXY2.y) * 0.00110;
            float3 ps1 = floor(PfbmS);
            float3 fs1 = PfbmS - ps1; fs1 = fs1*fs1*(3.0 - 2.0*fs1);
            float ns1 = dot(ps1, OFF);
            float s000 = fract(sin(ns1 + 0.0  ) * 43758.5453123);
            float s100 = fract(sin(ns1 + 1.0  ) * 43758.5453123);
            float s010 = fract(sin(ns1 + 57.0 ) * 43758.5453123);
            float s110 = fract(sin(ns1 + 58.0 ) * 43758.5453123);
            float s001 = fract(sin(ns1 + 113.0) * 43758.5453123);
            float s101 = fract(sin(ns1 + 114.0) * 43758.5453123);
            float s011 = fract(sin(ns1 + 170.0) * 43758.5453123);
            float s111 = fract(sin(ns1 + 171.0) * 43758.5453123);
            float sx00 = mix(s000, s100, fs1.x);
            float sx10 = mix(s010, s110, fs1.x);
            float sx01 = mix(s001, s101, fs1.x);
            float sx11 = mix(s011, s111, fs1.x);
            float sxy0 = mix(sx00, sx10, fs1.y);
            float sxy1 = mix(sx01, sx11, fs1.y);
            float densS = (0.5*mix(sxy0, sxy1, fs1.z));

            densS *= macroMask2;

            half occ  = half(densS);
            half aL   = half(1.0) - half(exp(-float(occ) * float(u_densityMul) * dL * 0.010));
            rho = half(min(1.0f, float(rho) * (1.0f - 0.55f * float(aL))));
        }

        // Short refinement
        half td = half(dt) * refineMul;
        for (int k=0; k<refineMax && T > half(0.004); ++k) {
            float3 sp2 = sp + N * (float(td) * float(k));
            // reuse the main density path in a very cheap way (one octave only)
            float2 xzq  = sp2.xz + u_domainOff;
            float2 xzrq = float2(xzq.x*ca - xzq.y*sa, xzq.x*sa + xzq.y*ca);
            float2 advQ = xzrq + u_wind * (u_time * 0.0035);
            float3 Pfq  = float3(advQ.x, sp2.y, advQ.y) * 0.00110;
            float3 pq   = floor(Pfq);
            float3 fq   = Pfq - pq; fq = fq*fq*(3.0 - 2.0*fq);
            float nq    = dot(pq, OFF);
            float q000 = fract(sin(nq + 0.0  ) * 43758.5453123);
            float q100 = fract(sin(nq + 1.0  ) * 43758.5453123);
            float q010 = fract(sin(nq + 57.0 ) * 43758.5453123);
            float q110 = fract(sin(nq + 58.0 ) * 43758.5453123);
            float q001 = fract(sin(nq + 113.0) * 43758.5453123);
            float q101 = fract(sin(nq + 114.0) * 43758.5453123);
            float q011 = fract(sin(nq + 170.0) * 43758.5453123);
            float q111 = fract(sin(nq + 171.0) * 43758.5453123);
            float qx00 = mix(q000, q100, fq.x);
            float qx10 = mix(q010, q110, fq.x);
            float qx01 = mix(q001, q101, fq.x);
            float qx11 = mix(q011, q111, fq.x);
            float qxy0 = mix(qx00, qx10, fq.y);
            float qxy1 = mix(qx01, qx11, fq.y);
            float densQ = 0.5*mix(qxy0, qxy1, fq.z);

            half sigma = half(max(0.0f, u_densityMul) * 0.036);
            half aStep = half(1.0) - half(exp(-float(densQ) * float(sigma) * float(td)));
            half gain  = half(clamp(0.90 + 0.22 * phaseHG, 0.0, 1.3));
            T *= (half(1.0) - aStep * gain);
            if (T <= half(0.004)) break;
        }

        t += dt;
    }

    half alpha = half(clamp(1.0 - float(T), 0.0, 1.0));
    _output.color = float4(alpha, alpha, alpha, alpha); // premultiplied white
    """

    @MainActor
    static func makeVolumetricImpostor(defaultSlabHalf: Float) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.diffuse.contents = UIColor.white

        m.shaderModifiers = [.fragment: fragSM]

        // Safe defaults (overwritten every frame by syncFromVolStore)
        m.setValue(0.0 as Float,             forKey: "u_time")
        m.setValue(simd_float2(0.60, 0.20),  forKey: "u_wind")
        m.setValue(simd_float2(0, 0),        forKey: "u_domainOff")
        m.setValue(0.0 as Float,             forKey: "u_domainRot")
        m.setValue(0.42 as Float,            forKey: "u_coverage")
        m.setValue(1.10 as Float,            forKey: "u_densityMul")
        m.setValue(0.70 as Float,            forKey: "u_stepMul")
        m.setValue(0.10 as Float,            forKey: "u_horizonLift")
        m.setValue(0.90 as Float,            forKey: "u_detailMul")
        m.setValue(0.0048 as Float,          forKey: "u_puffScale")
        m.setValue(0.62 as Float,            forKey: "u_puffStrength")
        m.setValue(0.00035 as Float,         forKey: "u_macroScale")
        m.setValue(0.58 as Float,            forKey: "u_macroThreshold")
        m.setValue(simd_float3(0,1,0),       forKey: "u_sunDir")
        m.setValue(defaultSlabHalf,          forKey: "u_slabHalf")

        m.setValue(volumetricMarker, forKey: "vapourTag")
        registry.add(m)
        return m
    }

    // Push current vapour uniforms into every impostor material.
    @MainActor
    static func syncFromVolStore() {
        let U = VolCloudUniformsStore.shared.snapshot()
        let time       = U.params0.x
        let wind       = simd_float2(U.params0.y, U.params0.z)
        let domainOff  = simd_float2(U.params3.x, U.params3.y)
        let domainRot  = U.params3.z
        let coverage   = U.params1.y
        let densityMul = U.params1.z
        let stepMul    = U.params1.w
        let horizon    = U.params2.z
        let detail     = U.params2.w
        let puffScale  = U.params3.w
        let puffStr    = U.params4.x
        let macroScale = U.params4.z
        let macroThr   = U.params4.w
        let sunDir     = simd_normalize(simd_float3(U.sunDirWorld.x, U.sunDirWorld.y, U.sunDirWorld.z))

        for m in registry.allObjects {
            m.setValue(time,          forKey: "u_time")
            m.setValue(wind,          forKey: "u_wind")
            m.setValue(domainOff,     forKey: "u_domainOff")
            m.setValue(domainRot,     forKey: "u_domainRot")
            m.setValue(coverage,      forKey: "u_coverage")
            m.setValue(densityMul,    forKey: "u_densityMul")
            m.setValue(stepMul,       forKey: "u_stepMul")
            m.setValue(horizon,       forKey: "u_horizonLift")
            m.setValue(detail,        forKey: "u_detailMul")
            m.setValue(puffScale,     forKey: "u_puffScale")
            m.setValue(puffStr,       forKey: "u_puffStrength")
            m.setValue(macroScale,    forKey: "u_macroScale")
            m.setValue(macroThr,      forKey: "u_macroThreshold")
            m.setValue(sunDir,        forKey: "u_sunDir")
        }
    }

    // Back-compat shim if any older code calls this name.
    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        makeVolumetricImpostor(defaultSlabHalf: 0.6)
    }
}
