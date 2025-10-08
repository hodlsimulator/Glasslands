//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric impostors via a fragment shader modifier only.
//  No SCNProgram, no SCNTechnique, no buffer binders.
//  Vapour sampling is anchored to the impostor’s model origin.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        // -------- uniforms --------
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;
        float baseY;
        float topY;
        float coverage;
        float densityMul;
        float stepMul;       // 0.35..1.25 (lower = faster)
        float detailMul;
        float horizonLift;
        float puffScale;
        float puffStrength;
        float macroScale;
        float macroThreshold;
        float2 domainOffset; // XZ
        float  domainRotate; // radians

        // -------- helpers --------
        #pragma declarations
        inline float hash1(float n) { return fract(sin(n) * 43758.5453123); }
        inline float hash12(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

        inline float noise3(float3 x) {
            float3 p = floor(x), f = x - p;
            f = f * f * (3.0 - 2.0 * f);
            const float3 off = float3(1.0, 57.0, 113.0);
            float n = dot(p, off);
            float n000 = hash1(n + 0.0),   n100 = hash1(n + 1.0);
            float n010 = hash1(n + 57.0),  n110 = hash1(n + 58.0);
            float n001 = hash1(n + 113.0), n101 = hash1(n + 114.0);
            float n011 = hash1(n + 170.0), n111 = hash1(n + 171.0);
            float nx00 = mix(n000, n100, f.x), nx10 = mix(n010, n110, f.x);
            float nx01 = mix(n001, n101, f.x), nx11 = mix(n011, n111, f.x);
            float nxy0 = mix(nx00, nx10, f.y), nxy1 = mix(nx01, nx11, f.y);
            return mix(nxy0, nxy1, f.z);
        }

        inline float fbm2(float3 p) {
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
                float2 o = float2(hash12(i+g), hash12(i+g+19.7));
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

        inline float3 worldPos_fromViewPos(float3 viewPos) {
            // _surface.position is in view space; lift to world space.
            float4 w = scn_frame.inverseViewTransform * float4(viewPos, 1.0);
            return w.xyz / max(1e-6, w.w);
        }

        inline float3x3 nodeBasis(float4x4 m){
            float3 ux = normalize(m[0].xyz);
            float3 vy = normalize(m[1].xyz);
            float3 n  = normalize(cross(ux, vy));
            return float3x3(ux, vy, n);
        }

        inline float3 nodeOrigin(float4x4 m){
            float4 o4 = m * float4(0,0,0,1);
            return o4.xyz / max(1e-6, o4.w);
        }

        inline float densityAtAnchored(float3 wp, float2 anchorXZ)
        {
            float2 xzRel = (wp.xz - anchorXZ) + domainOffset;
            float ca = cos(domainRotate), sa = sin(domainRotate);
            float2 xzr = float2(xzRel.x*ca - xzRel.y*sa,
                                xzRel.x*sa + xzRel.y*ca);

            float3 P0 = float3(xzr.x, wp.y, xzr.y) * 0.00110;
            float base = fbm2(P0 * float3(1.0, 0.35, 1.0));

            float yy = wp.y * 0.002 + 5.37;
            float puffs = puffFBM2(xzr * max(1e-4, puffScale) + float2(yy, -yy*0.7));

            float3 P1 = float3(xzr.x, wp.y*1.6, xzr.y) * 0.0040 + float3(2.7,0.0,-5.1);
            float erode = fbm2(P1);

            float shape = base + puffStrength*(puffs - 0.5) - (1.0 - erode) * (0.30 * detailMul);

            float coverInv = 1.0 - coverage;
            float thLo = clamp(coverInv - 0.20, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.28, 0.0, 1.2);
            float t    = smoothstep(thLo, thHi, shape);

            float dens = pow(clamp(t, 0.0, 1.0), 0.85);

            float macro = 1.0 - clamp(worley2(xzr * max(1e-6, macroScale)), 0.0, 1.0);
            float macroMask = smoothstep(macroThreshold - 0.10, macroThreshold + 0.10, macro);
            dens *= macroMask;

            dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
            return dens;
        }

        // -------- fragment body --------
        #pragma body
        // Node basis and origin in world space
        float4x4 M = scn_node.modelTransform;
        float3x3 B = nodeBasis(M);
        float3 ux = B[0];
        float3 vy = B[1];
        float3 nrm = B[2];
        float3 origin = nodeOrigin(M);
        float2 anchorXZ = origin.xz;

        // World position and view ray
        float3 wp0 = worldPos_fromViewPos(_surface.position);
        float3 Vworld = normalize((scn_frame.inverseViewTransform * float4(normalize(_surface.view), 0)).xyz);

        // Slab thickness from local half-extents
        float worldHalfX = length(M[0].xyz) * max(0.0001, impostorHalfW);
        float worldHalfY = length(M[1].xyz) * max(0.0001, impostorHalfH);
        float slabHalf   = max(worldHalfX, worldHalfY) * 0.9;

        // Centre-on-plane ray march (cheap and stable)
        float3 wpPlane = wp0; // current fragment is on the billboard already
        float3 marchDir = Vworld;

        float Lm = slabHalf * 2.0;
        if (Lm <= 1e-5) { discard_fragment(); }

        float distLOD  = clamp(Lm / 2500.0, 0.0, 1.2);
        int   baseSteps = int(round(mix(8.0, 16.0, 1.0 - distLOD*0.7)));
        int   N = clamp(int(round(float(baseSteps) * clamp(stepMul, 0.35, 1.25))), 6, 20);
        float dt = Lm / float(N);

        // small per-fragment jitter to reduce banding
        float2 st = _surface.diffuseTexcoord;
        float j = fract(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453);
        float t  = -slabHalf + (0.25 + 0.5*j) * dt;

        float T = 1.0;
        for (int i=0; i<N && T>0.004; ++i)
        {
            float3 sp = wpPlane + marchDir * t;

            // Edge falloff in plane space
            float3 d = sp - origin;
            float lpX = dot(d, ux);
            float lpY = dot(d, vy);
            float er = length(float2(lpX/worldHalfX, lpY/worldHalfY));
            float edge = smoothstep(1.0, 0.95, 1.0 - er);

            float rho = densityAtAnchored(sp, anchorXZ) * edge;
            if (rho > 0.0025) {
                float aStep = 1.0 - exp(-max(0.0, densityMul) * 0.032 * rho * dt);
                T *= (1.0 - aStep);
            }
            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha; // premultiplied white
        _output.color = float4(rgb, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne

        m.shaderModifiers = [.fragment: frag]

        // Defaults tuned for mobile performance
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")
        m.setValue(400.0 as CGFloat, forKey: "baseY")
        m.setValue(1400.0 as CGFloat, forKey: "topY")
        m.setValue(0.42 as CGFloat, forKey: "coverage")
        m.setValue(1.05 as CGFloat, forKey: "densityMul")
        m.setValue(0.75 as CGFloat, forKey: "stepMul")
        m.setValue(0.90 as CGFloat, forKey: "detailMul")
        m.setValue(0.08 as CGFloat, forKey: "horizonLift")
        m.setValue(0.0045 as CGFloat, forKey: "puffScale")
        m.setValue(0.65 as CGFloat, forKey: "puffStrength")
        m.setValue(0.00035 as CGFloat, forKey: "macroScale")
        m.setValue(0.58 as CGFloat, forKey: "macroThreshold")
        m.setValue(SIMD2<Float>(0, 0), forKey: "domainOffset")
        m.setValue(0.0 as CGFloat, forKey: "domainRotate")

        // Atlas tint preserved by caller; set neutral here.
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
