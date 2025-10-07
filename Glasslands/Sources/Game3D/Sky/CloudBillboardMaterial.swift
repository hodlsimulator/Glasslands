//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Volumetric billboard impostor via a fragment-only SceneKit shader modifier.
//  No SCNProgram, no geometry modifier, no helper function definitions.
//  Each quad integrates vapour in a thin world-space slab around the quad’s plane.
//

import SceneKit
import UIKit
import simd

enum CloudBillboardMaterial {

    private static var registry = NSHashTable<SCNMaterial>.weakObjects()
    static let volumetricMarker = "/* VAPOUR_IMPOSTOR_SM_V2 */"

    // Fragment-only modifier: defines uniforms (#pragma arguments) and the body (#pragma body).
    private static let fragSM: String =
    """
    #pragma transparent

    #pragma arguments
    // Per-frame uniforms (pushed from VolCloudUniformsStore via syncFromVolStore)
    float  u_time;
    float2 u_wind;          // world wind (x,z)
    float2 u_domainOff;     // advection offset (x,z)
    float  u_domainRot;     // radians
    float  u_coverage;      // 0..1
    float  u_densityMul;    // thickness multiplier
    float  u_stepMul;       // 0.60..1.35
    float  u_detailMul;     // erosion
    float  u_puffScale;     // micro puffs frequency
    float  u_puffStrength;  // micro puffs strength
    float  u_macroScale;    // island mask frequency
    float  u_macroThreshold;// island mask threshold [0,1]
    float  u_horizonLift;   // subtle vertical lift
    float3 u_sunDir;        // world sun dir (normalized)
    // Per-material: world half-thickness of the slab for this quad
    float  u_slabHalf;

    #pragma body
    // === Minimal helpers written inline ===

    // Value noise 3D (inline)
    float valueNoise3(float3 x) {
        float3 p = floor(x);
        float3 f = x - p;
        f = f*f*(3.0 - 2.0*f);
        const float3 off = float3(1.0, 57.0, 113.0);
        float n = dot(p, off);
        float n000 = fract(sin(n + 0.0 ) * 43758.5453123);
        float n100 = fract(sin(n + 1.0 ) * 43758.5453123);
        float n010 = fract(sin(n + 57.0) * 43758.5453123);
        float n110 = fract(sin(n + 58.0) * 43758.5453123);
        float n001 = fract(sin(n + 113.0) * 43758.5453123);
        float n101 = fract(sin(n + 114.0) * 43758.5453123);
        float n011 = fract(sin(n + 170.0) * 43758.5453123);
        float n111 = fract(sin(n + 171.0) * 43758.5453123);
        float nx00 = mix(n000, n100, f.x);
        float nx10 = mix(n010, n110, f.x);
        float nx01 = mix(n001, n101, f.x);
        float nx11 = mix(n011, n111, f.x);
        float nxy0 = mix(nx00, nx10, f.y);
        float nxy1 = mix(nx01, nx11, f.y);
        return mix(nxy0, nxy1, f.z);
    }

    // Two-octave 3D fbm (inline)
    float fbm2_3d(float3 p){
        float a = 0.0;
        float w = 0.5;
        a += valueNoise3(p) * w;
        p = p * 2.02 + 19.19; w *= 0.5;
        a += valueNoise3(p) * w;
        return a;
    }

    // Cheap 2D Worley distance (inline, 3x3 neighborhood)
    float worley2(float2 x){
        float2 i = floor(x);
        float2 f = x - i;
        float d = 1e9;
        for (int yy=-1; yy<=1; ++yy){
            for (int xx=-1; xx<=1; ++xx){
                float2 g = float2(xx,yy);
                float2 o = float2(
                    fract(sin(dot(i+g, float2(127.1,311.7))) * 43758.5453123),
                    fract(sin(dot(i+g, float2(269.5,183.3))) * 43758.5453123)
                );
                float2 r = g + o - f;
                d = min(d, dot(r,r));
            }
        }
        return sqrt(max(d,0.0));
    }

    // Phase HG (inline)
    float phaseHG(float mu, float g){
        float g2 = g*g;
        return (1.0 - g2) / max(1e-4, 4.0*3.14159265358979323846*pow(1.0 + g2 - 2.0*g*mu, 1.5));
    }

    // Camera & view ray
    float3 camPos = (u_inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float3 V = normalize(_surface.position - camPos);

    // Plane normal (world) and a soft edge mask from UV
    float3 N = normalize(_surface.normal);
    float2 uv01 = _surface.diffuseTexcoord;
    float2 uv = uv01*2.0 - 1.0;
    float edgeMask = smoothstep(1.0, 0.92, 1.0 - length(uv));

    // Integrate a slab centered at the current plane point
    float tEnt = -u_slabHalf;
    float tExt =  u_slabHalf;
    float Lm   = tExt - tEnt;
    if (Lm <= 1e-5) { discard_fragment(); }

    float distLOD   = clamp(Lm / 2500.0, 0.0, 1.2);
    float stepMul   = clamp(u_stepMul, 0.60, 1.35);
    int   baseSteps = int(round(mix(10.0, 18.0, 1.0 - distLOD*0.7)));
    int   numSteps  = clamp(int(round(float(baseSteps) * stepMul)), 8, 24);
    float dt        = Lm / float(numSteps);

    // Jitter
    float j = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    float t = tEnt + (0.25 + 0.5*j) * dt;

    // Lighting
    half3 S  = half3(normalize(u_sunDir));
    half mu  = half(clamp(dot(V, float3(S)), -1.0, 1.0));
    half g   = half(0.60);

    // Domain rotation
    float ca = cos(u_domainRot), sa = sin(u_domainRot);

    // Inline density sampler (same spirit as the dome, simplified)
    auto sampleDensity = [&](float3 wp) -> float {
        float baseY = 400.0;
        float topY  = 1400.0;

        float h = clamp((wp.y-baseY)/max(1.0,(topY-baseY)), 0.0, 1.0);
        float up = smoothstep(0.03, 0.25, h);
        float dn = 1.0 - smoothstep(0.68, 1.00, h);
        float h01 = pow(clamp(up*dn, 0.0, 1.0), 0.80);

        float2 xz = wp.xz + u_domainOff;
        float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

        float adv    = mix(0.55, 1.55, h01);
        float2 advXY = xzr + u_wind * adv * (u_time * 0.0035);

        float macro     = 1.0 - clamp(worley2(advXY * u_macroScale), 0.0, 1.0);
        float macroMask = smoothstep(u_macroThreshold - 0.10, u_macroThreshold + 0.10, macro);

        float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
        float  base = fbm2_3d(P0 * float3(1.0, 0.35, 1.0));

        float  yy    = wp.y * 0.002 + 5.37;
        float  puffs = 0.0;
        {   // two-octave inverted Worley
            float a = 0.0, w = 0.6, s = 1.0;
            float v = 1.0 - clamp(worley2(advXY * u_puffScale * s + float2(yy, -yy*0.7)), 0.0, 1.0);
            a += v*w; s *= 2.03; w *= 0.55;
            v = 1.0 - clamp(worley2(advXY * u_puffScale * s + float2(yy*1.3, yy*0.5)), 0.0, 1.0);
            a += v*w;
            puffs = clamp(a, 0.0, 1.0);
        }

        float3 P1 = float3(advXY.x, wp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
        float  erode = fbm2_3d(P1);

        float shape = base + u_puffStrength*(puffs - 0.5)
                    - (1.0 - erode) * (0.30 * u_detailMul);

        float coverInv = 1.0 - u_coverage;
        float thLo     = clamp(coverInv - 0.20, 0.0, 1.0);
        float thHi     = clamp(coverInv + 0.28, 0.0, 1.2);
        float gate     = smoothstep(thLo, thHi, shape);
        float dens     = pow(clamp(gate, 0.0, 1.0), 0.85);

        dens *= macroMask;
        dens *= hProfile(wp.y + u_horizonLift*120.0, baseY, topY);
        return dens;
    };

    half T = half(1.0);
    const half refineMul = half(0.45);
    const int  refineMax = 2;

    for (int i=0; i<numSteps && T > half(0.004); ++i) {
        float3 sp = _surface.position + V * t;

        half rho = half(sampleDensity(sp)) * half(edgeMask);
        if (rho < half(0.0025)) { t += dt; continue; }

        // one-tap sun probe folded into extinction
        {
            float dL = 200.0;
            float3 lpSun = sp + float3(S) * dL;
            half occ  = half(sampleDensity(lpSun));
            half aL   = half(1.0) - half(exp(-float(occ) * float(u_densityMul) * dL * 0.010));
            rho = half(min(1.0f, float(rho) * (1.0f - 0.55f * float(aL))));
        }

        // short refinement
        half td = half(dt) * refineMul;
        for (int k=0; k<refineMax && T > half(0.004); ++k) {
            float3 sp2 = sp + V * (float(td) * float(k));
            half rho2  = half(sampleDensity(sp2));
            half sigma = half(max(0.0f, u_densityMul) * 0.036);
            half aStep = half(1.0) - half(exp(-float(rho2) * float(sigma) * float(td)));
            half ph    = half(phaseHG(clamp(dot(V, float3(S)), -1.0, 1.0), 0.60));
            half gain  = half(clamp(0.90 + 0.22 * float(ph), 0.0, 1.3));
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
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.diffuse.contents = UIColor.white

        m.shaderModifiers = [.fragment: fragSM]

        // Minimal safe defaults; per-frame sync will overwrite these.
        m.setValue(0.0 as Float,             forKey: "u_time")
        m.setValue(simd_float2(0.60, 0.20),  forKey: "u_wind")
        m.setValue(simd_float2(0, 0),        forKey: "u_domainOff")
        m.setValue(0.0 as Float,             forKey: "u_domainRot")
        m.setValue(0.42 as Float,            forKey: "u_coverage")
        m.setValue(1.10 as Float,            forKey: "u_densityMul")
        m.setValue(0.90 as Float,            forKey: "u_detailMul")
        m.setValue(0.0048 as Float,          forKey: "u_puffScale")
        m.setValue(0.62 as Float,            forKey: "u_puffStrength")
        m.setValue(0.00035 as Float,         forKey: "u_macroScale")
        m.setValue(0.58 as Float,            forKey: "u_macroThreshold")
        m.setValue(0.70 as Float,            forKey: "u_stepMul")
        m.setValue(0.10 as Float,            forKey: "u_horizonLift")
        m.setValue(simd_float3(0,1,0),       forKey: "u_sunDir")
        m.setValue(defaultSlabHalf,          forKey: "u_slabHalf")

        m.setValue(volumetricMarker, forKey: "vapourTag")
        registry.add(m)
        return m
    }

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

    // compatibility shim
    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        makeVolumetricImpostor(defaultSlabHalf: 0.5)
    }
}
