//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Volumetric billboard impostor via SceneKit shader modifiers (Metal).
//  No SCNProgram, no textures/samplers, no 2D shapes — each quad integrates
//  real vapour within a thin slab around the billboard plane.
//

import SceneKit
import UIKit
import simd

enum CloudBillboardMaterial {

    // Track all materials so we can push per-frame uniforms once.
    private static var registry = NSHashTable<SCNMaterial>.weakObjects()

    static let volumetricMarker = "/* VAPOUR_IMPOSTOR_SM */"

    // Shared shader (geometry+fragment) — Metal inserted by SceneKit.
    private static let geomSM: String =
    """
    #pragma arguments
    // no custom args in geometry stage

    #pragma varyings
    float3 v_origin;
    float3 v_ux;
    float3 v_vy;
    float3 v_nrm;

    #pragma body
    // World origin of the quad (node origin).
    v_origin = (u_modelTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

    // World-space basis of the plane (columns of model matrix).
    float3 ex = (u_modelTransform * float4(1.0, 0.0, 0.0, 0.0)).xyz;
    float3 ey = (u_modelTransform * float4(0.0, 1.0, 0.0, 0.0)).xyz;
    v_ux = normalize(ex);
    v_vy = normalize(ey);
    v_nrm = normalize(cross(v_ux, v_vy));
    """

    private static let fragSM: String =
    """
    #pragma transparent
    #pragma arguments
    float  u_time;
    float2 u_wind;          // world wind (x,z)
    float2 u_domainOff;     // large-scale advection offset
    float  u_domainRot;     // rotation of domain (radians)
    float  u_coverage;      // 0..1
    float  u_densityMul;    // thickness scaler
    float  u_stepMul;       // 0.6..1.35
    float  u_detailMul;     // erosion detail
    float  u_puffScale;     // micro puff frequency
    float  u_puffStrength;  // micro puff influence
    float  u_macroScale;    // island mask frequency
    float  u_macroThreshold;// island mask threshold
    float  u_horizonLift;   // subtle lift
    float3 u_sunDir;        // world dir, normalised

    #pragma varyings
    float3 v_origin;
    float3 v_ux;
    float3 v_vy;
    float3 v_nrm;

    // ---- helpers (Metal) ----
    inline float h1(float n){ return fract(sin(n) * 43758.5453123); }
    inline float h12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

    inline float noise3(float3 x) {
        float3 p = floor(x), f = x - p;
        f = f * f * (3.0 - 2.0 * f);
        const float3 off = float3(1.0, 57.0, 113.0);
        float n = dot(p, off);
        float n000 = h1(n + 0.0),   n100 = h1(n + 1.0);
        float n010 = h1(n + 57.0),  n110 = h1(n + 58.0);
        float n001 = h1(n + 113.0), n101 = h1(n + 114.0);
        float n011 = h1(n + 170.0), n111 = h1(n + 171.0);
        float nx00 = mix(n000, n100, f.x), nx10 = mix(n010, n110, f.x);
        float nx01 = mix(n001, n101, f.x), nx11 = mix(n011, n111, f.x);
        float nxy0 = mix(nx00, nx10, f.y), nxy1 = mix(nx01, nx11, f.y);
        return mix(nxy0, nxy1, f.z);
    }

    inline float fbm2(float3 p){
        float a = 0.0, w = 0.5;
        a += noise3(p) * w;
        p = p * 2.02 + 19.19; w *= 0.5;
        a += noise3(p) * w;
        return a;
    }

    inline float worley2(float2 x){
        float2 i = floor(x), f = x - i;
        float d = 1e9;
        for (int y=-1; y<=1; ++y)
        for (int xk=-1; xk<=1; ++xk){
            float2 g = float2(xk,y);
            float2 o = float2(h12(i+g), h12(i+g+19.7));
            float2 r = g + o - f;
            d = min(d, dot(r,r));
        }
        return sqrt(max(d,0.0));
    }

    inline float puffFBM2(float2 x){
        float a = 0.0, w = 0.6, s = 1.0;
        float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
        a += v*w; s *= 2.03; w *= 0.55;
        v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
        a += v*w;
        return clamp(a, 0.0, 1.0);
    }

    inline float hProfile(float y, float b, float t){
        float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
        float up = smoothstep(0.03, 0.25, h);
        float dn = 1.0 - smoothstep(0.68, 1.00, h);
        return pow(clamp(up*dn, 0.0, 1.0), 0.80);
    }

    inline float phaseHG(float mu, float g){
        float g2 = g*g;
        return (1.0 - g2) / max(1e-4, 4.0*3.14159265358979323846*pow(1.0 + g2 - 2.0*g*mu, 1.5));
    }

    inline float densityAt(float3 wp){
        // Height slab  (use the classic 400..1400 defaults; b/t aren’t exposed here)
        float baseY = 400.0;
        float topY  = 1400.0;

        float h01 = hProfile(wp.y, baseY, topY);

        // Domain rotation + offset
        float ca = cos(u_domainRot), sa = sin(u_domainRot);
        float2 xz = wp.xz + u_domainOff;
        float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

        float adv    = mix(0.55, 1.55, h01);
        float2 advXY = xzr + u_wind * adv * (u_time * 0.0035);

        // Macro islands → scattered cumulus
        float macro     = 1.0 - clamp(worley2(advXY * u_macroScale), 0.0, 1.0);
        float macroMask = smoothstep(u_macroThreshold - 0.10, u_macroThreshold + 0.10, macro);

        // Base + micro puffs + erosion
        float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
        float  base = fbm2(P0 * float3(1.0, 0.35, 1.0));

        float  yy    = wp.y * 0.002 + 5.37;
        float  puffs = puffFBM2(advXY * u_puffScale + float2(yy, -yy*0.7));

        float3 P1 = float3(advXY.x, wp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
        float  erode = fbm2(P1);

        float  shape = base + u_puffStrength*(puffs - 0.5)
                     - (1.0 - erode) * (0.30 * u_detailMul);

        float coverInv = 1.0 - u_coverage;
        float thLo     = clamp(coverInv - 0.20, 0.0, 1.0);
        float thHi     = clamp(coverInv + 0.28, 0.0, 1.2);
        float  t       = smoothstep(thLo, thHi, shape);
        float  dens    = pow(clamp(t, 0.0, 1.0), 0.85);

        dens *= macroMask;
        dens *= hProfile(wp.y + u_horizonLift*120.0, baseY, topY);
        return dens;
    }

    #pragma body
    // World camera
    float3 camPos = (u_inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

    // View ray through this fragment
    float3 V = normalize(_surface.position - camPos);

    // Intersect with the billboard plane and define a thin world-space slab.
    float denom = dot(V, v_nrm);
    if (fabs(denom) < 1e-4) { discard_fragment(); }

    float tPlane = dot(v_origin - camPos, v_nrm) / denom;

    // Scale slab thickness by the quad’s world axes and how close we are to centre.
    float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;          // -1..1 across quad
    float  centreBias = clamp(1.0 - length(uv), 0.0, 1.0);     // 1 centre → 0 edge
    float  worldAxis  = 0.5 * (length(v_ux) + length(v_vy));   // scale factor for local units
    float  slabHalf   = worldAxis * mix(0.6, 1.2, centreBias); // thicker near centre

    float tEnt = max(0.0, tPlane - slabHalf);
    float tExt =         tPlane + slabHalf;
    float Lm   = tExt - tEnt;
    if (Lm <= 1e-5) { discard_fragment(); }

    // Steps with distance LOD.
    float distLOD   = clamp(Lm / 2500.0, 0.0, 1.2);
    float stepMul   = clamp(u_stepMul, 0.60, 1.35);
    int   baseSteps = int(round(mix(10.0, 18.0, 1.0 - distLOD*0.7)));
    int   numSteps  = clamp(int(round(float(baseSteps) * stepMul)), 8, 24);
    float dt        = Lm / float(numSteps);

    // De-emphasise hard quad edges
    float edgeMask = smoothstep(1.0, 0.92, 1.0 - length(uv));

    // Jitter to hide banding
    float j = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    float t = tEnt + (0.25 + 0.5*j) * dt;

    // Lighting
    half3 S  = half3(normalize(u_sunDir));
    half mu  = half(clamp(dot(V, float3(S)), -1.0, 1.0));
    half g   = half(0.60);   // Mie g — kept constant here

    half T = half(1.0);
    const half rhoGate   = half(0.0025);
    const half refineMul = half(0.45);
    const int  refineMax = 2;

    for (int i=0; i < numSteps && T > half(0.004); ++i) {
        float3 sp = camPos + V * t;

        half rho = half(densityAt(sp)) * half(edgeMask);
        if (rho < rhoGate) { t += dt; continue; }

        // One-tap sun probe folded into extinction
        {
            float dL = 200.0; // small fixed probe distance
            float3 lpSun = sp + float3(S) * dL;
            half occ  = half(densityAt(lpSun));
            half aL   = half(1.0) - half(exp(-float(occ) * float(u_densityMul) * dL * 0.010));
            rho = half(min(1.0f, float(rho) * (1.0f - 0.55f * float(aL))));
        }

        // Short refinement
        half td = half(dt) * refineMul;
        for (int k=0; k < refineMax && T > half(0.004); ++k) {
            float3 sp2 = sp + V * (float(td) * float(k));
            half rho2  = half(densityAt(sp2));
            half sigma = half(max(0.0f, u_densityMul) * 0.036);
            half aStep = half(1.0) - half(exp(-float(rho2) * float(sigma) * float(td)));
            half ph    = half(phaseHG(float(mu), float(g)));
            half gain  = half(clamp(0.90 + 0.22 * float(ph), 0.0, 1.3));
            T *= (half(1.0) - aStep * gain);
            if (T <= half(0.004)) break;
        }

        t += dt;
    }

    half alpha = half(clamp(1.0 - float(T), 0.0, 1.0));
    _output.color = float4(alpha, alpha, alpha, alpha); // premultiplied white
    """

    // Create a material with the volumetric impostor shader modifiers attached.
    @MainActor
    static func makeVolumetricImpostor(defaultHalfSize: simd_float2 = .init(1, 1)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne

        m.shaderModifiers = [
            .geometry: geomSM,
            .fragment: fragSM
        ]

        // Diffuse is ignored by the shader, but SceneKit expects something valid.
        m.diffuse.contents = UIColor.white

        // Reasonable defaults (will be pushed every frame from the store).
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

        m.setValue(volumetricMarker, forKey: "vapourTag")

        registry.add(m)
        return m
    }

    // Push the current VolCloudUniformsStore values into all impostor materials.
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

    // Kept for compatibility (menus etc. may call it); returns the impostor material above.
    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        makeVolumetricImpostor()
    }
}
