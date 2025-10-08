//
//  CloudImpostorMaterial.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//
//  Volumetric vapour impostors using a fragment shader modifier.
//  No SCNProgram buffer binding; all uniforms are plain #pragma arguments.
//  Vapour density is ANCHORED to the plane’s model origin (so it moves as a unit).
//

import SceneKit
import simd
import UIKit

enum CloudImpostorMaterial {
    @MainActor
    static func make(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        // ---------- uniforms ----------
        #pragma arguments
        float impostorHalfW;     // local half width
        float impostorHalfH;     // local half height
        float baseY;             // slab bottom world Y
        float topY;              // slab top    world Y
        float coverage;          // 0..1
        float densityMul;        // overall sigma scale (~1.1)
        float stepMul;           // 0.35..1.25
        float detailMul;         // erode amount
        float horizonLift;       // 0..1 (vertical bias)
        float puffScale;         // micro puff size
        float puffStrength;      // micro vs base blend
        float macroScale;        // macro breakup
        float macroThreshold;    // macro gate 0..1
        float2 wind;             // XZ
        float2 domainOffset;     // XZ
        float  domainRotate;     // radians

        // ---------- helpers ----------
        float fractf(float x){ return x - floor(x); }
        float hash1(float n){ return fractf(sin(n) * 43758.5453123); }
        float hash12(float2 p){ return fractf(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

        float noise3(float3 x){
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

        float fbm2(float3 p){
            float a = 0.0, w = 0.5;
            a += noise3(p) * w;
            p = p * 2.02 + 19.19; w *= 0.5;
            a += noise3(p) * w;
            return a;
        }

        float worley2(float2 x){
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

        float puffFBM2(float2 x){
            float a = 0.0, w = 0.6, s = 1.0;
            float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w; s *= 2.03; w *= 0.55;
            v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w;
            return clamp(a, 0.0, 1.0);
        }

        float hProfile(float y, float b, float t){
            float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
            float up = smoothstep(0.03, 0.25, h);
            float dn = 1.0 - smoothstep(0.68, 1.00, h);
            return pow(clamp(up*dn, 0.0, 1.0), 0.80);
        }

        // ---------- density anchored to impostor origin ----------
        float densityAtAnchored(float3 wp, float2 anchorXZ)
        {
            float2 xzRel = (wp.xz - anchorXZ) + domainOffset;
            float ca = cos(domainRotate), sa = sin(domainRotate);
            float2 xzr = float2(xzRel.x*ca - xzRel.y*sa,
                                xzRel.x*sa + xzRel.y*ca);

            float h01 = hProfile(wp.y, baseY, topY);
            float adv = mix(0.55, 1.55, h01);
            float2 advXY = xzr + wind * adv * 0.0; // time term omitted (impostors advect physically)

            float macro = 1.0 - clamp(worley2(advXY * macroScale), 0.0, 1.0);
            float macroMask = smoothstep(macroThreshold - 0.10, macroThreshold + 0.10, macro);

            float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
            float base = fbm2(P0 * float3(1.0, 0.35, 1.0));

            float yy = wp.y * 0.002 + 5.37;
            float puffs = puffFBM2(advXY * max(1e-4, puffScale) + float2(yy, -yy*0.7));

            float3 P1 = float3(advXY.x, wp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
            float erode = fbm2(P1);

            float shape = base + puffStrength*(puffs - 0.5) - (1.0 - erode) * (0.30 * detailMul);
            float coverInv = 1.0 - coverage;
            float thLo = clamp(coverInv - 0.20, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.28, 0.0, 1.2);
            float t    = smoothstep(thLo, thHi, shape);

            float dens = pow(clamp(t, 0.0, 1.0), 0.85);
            dens *= macroMask;
            dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
            return dens;
        }

        // ---------- FRAGMENT ----------
        {
            // Camera position and view ray
            float3 camPos = (u_inverseViewTransform * float4(0,0,0,1)).xyz;
            float3 V = normalize(_surface.position - camPos);

            // Model basis (plane axes) + origin
            float3 ux   = normalize(u_modelTransform[0].xyz);
            float3 vy   = normalize(u_modelTransform[1].xyz);
            float3 nrm  = normalize(cross(ux, vy));
            float3 origin = (u_modelTransform * float4(0,0,0,1)).xyz;
            float2 anchorXZ = origin.xz;

            float denom = dot(V, nrm);
            if (denom < 0.0) { nrm = -nrm; denom = -denom; }
            if (denom < 1e-5) { discard_fragment(); }

            float tPlane = dot(origin - camPos, nrm) / denom;
            if (tPlane < 0.0) { discard_fragment(); }

            float worldHalfX = length(u_modelTransform[0].xyz) * max(0.0001, impostorHalfW);
            float worldHalfY = length(u_modelTransform[1].xyz) * max(0.0001, impostorHalfH);
            float slabHalf   = max(worldHalfX, worldHalfY) * 0.9;

            float tEnt = max(0.0, tPlane - slabHalf);
            float tExt = tPlane + slabHalf;
            float Lm   = tExt - tEnt;
            if (Lm <= 1e-5) { discard_fragment(); }

            int   Nbase = 12;
            int   N = clamp(int(round(float(Nbase) * clamp(stepMul, 0.35, 1.25))), 6, 20);
            float dt = Lm / float(N);
            float t  = tEnt + dt * 0.5;

            float T = 1.0;
            for (int i=0; i<N && T>0.004; ++i)
            {
                float3 sp = camPos + V * t;

                // Edge falloff in plane space
                float3 d = sp - origin;
                float lpX = dot(d, ux);
                float lpY = dot(d, vy);
                float er = length(float2(lpX/worldHalfX, lpY/worldHalfY));
                float edgeMask = smoothstep(1.0, 0.95, 1.0 - er);

                float rho = densityAtAnchored(sp, anchorXZ) * edgeMask;
                if (rho < 0.0025) { t += dt; continue; }

                float sigma = max(0.0, densityMul) * 0.032;
                float aStep = 1.0 - exp(-rho * sigma * dt);
                T *= (1.0 - aStep);
                t += dt;
            }

            float alpha = clamp(1.0 - T, 0.0, 1.0);
            float3 rgb  = float3(1.0) * alpha;  // premultiplied white
            _output.color = float4(rgb, alpha);
        }
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

        // Defaults (safe/fast)
        m.setValue(halfW, forKey: "impostorHalfW")
        m.setValue(halfH, forKey: "impostorHalfH")
        m.setValue(400.0 as CGFloat, forKey: "baseY")
        m.setValue(1400.0 as CGFloat, forKey: "topY")
        m.setValue(0.44 as CGFloat, forKey: "coverage")
        m.setValue(1.10 as CGFloat, forKey: "densityMul")
        m.setValue(0.80 as CGFloat, forKey: "stepMul")
        m.setValue(0.90 as CGFloat, forKey: "detailMul")
        m.setValue(0.10 as CGFloat, forKey: "horizonLift")
        m.setValue(0.0046 as CGFloat, forKey: "puffScale")
        m.setValue(0.68 as CGFloat, forKey: "puffStrength")
        m.setValue(0.00040 as CGFloat, forKey: "macroScale")
        m.setValue(0.58 as CGFloat, forKey: "macroThreshold")
        m.setValue(SCNVector3(0.60, 0.20, 0), forKey: "wind")
        m.setValue(SCNVector3(0, 0, 0), forKey: "domainOffset")
        m.setValue(0.0 as CGFloat, forKey: "domainRotate")

        // Visual parity: keep white like the sprite path
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
