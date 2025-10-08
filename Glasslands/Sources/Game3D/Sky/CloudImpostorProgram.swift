//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Ultra-dense, clumped cauliflower vapour with hidden billboard rims.
//  Sun-only white. GPU-cheap via 5-slice analytic integration (no ray march).
//  Crisp overhead puffs (screen-space detail boost).
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {

        let frag = """
        #pragma transparent

        // ===== uniforms (SceneKit requires one per line) =====
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;

        float stepMul;       // kept for compat (not used by integration)
        float densityMul;    // extinction strength
        float thickness;     // slab depth
        float densBias;

        float coverage;      // macro fullness
        float puffScale;     // base micro scale
        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;
        float edgeErode;
        float centreFill;
        float shapeScale;
        float shapeLo;
        float shapeHi;
        float shapeSeed;

        float rimFeatherBoost;
        float rimFadePow;
        float shapePow;

        float coreFloor;     // tiny density floor inside core (kills holes)

        float3 sunDirView;
        float hgG;
        float baseWhite;
        float hiGain;
        float edgeSoft;      // unused for lighting
        float microAmp;
        float occK;

        // ===== helpers =====
        #pragma declarations
        inline float hash1(float n){ return fract(sin(n) * 43758.5453123); }
        inline float hash12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

        inline float noise3(float3 x){
            float3 p=floor(x), f=x-p; f=f*f*(3.0-2.0*f);
            const float3 off=float3(1.0,57.0,113.0);
            float n=dot(p,off);
            float n000=hash1(n+0.0), n100=hash1(n+1.0), n010=hash1(n+57.0), n110=hash1(n+58.0);
            float n001=hash1(n+113.0),n101=hash1(n+114.0),n011=hash1(n+170.0),n111=hash1(n+171.0);
            float nx00=mix(n000,n100,f.x), nx10=mix(n010,n110,f.x);
            float nx01=mix(n001,n101,f.x), nx11=mix(n011,n111,f.x);
            float nxy0=mix(nx00,nx10,f.y), nxy1=mix(nx01,nx11,f.y);
            return mix(nxy0,nxy1,f.z);
        }

        // cheap 2D "lump" – circle inside a jittered cell (4-neighbour max)
        inline float lump4(float2 p){
            float2 c = floor(p), f = p - c;
            float v = 0.0;

            for (int oy = 0; oy <= 1; ++oy)
            for (int ox = 0; ox <= 1; ++ox) {
                float2 ic = c + float2(ox, oy);
                float2 rnd = float2(hash12(ic), hash12(ic + 19.7));
                float2 q = f - float2(ox, oy) - rnd;    // centre in each neighbour
                float d2 = dot(q,q);
                float rad = 0.35 + 0.27 * hash12(ic + 7.3);
                float r2  = rad * rad;
                // soft circle – no sqrt
                float s = smoothstep(r2, r2 * (1.0 - 0.48), d2);
                v = max(v, s);
            }
            return v;
        }

        // layered cauliflower micro-field (no Worley loops; very cheap)
        inline float cauliflower(float2 uv, float z, float baseScale, float detailBoost){
            float s0 = baseScale * 180.0 * detailBoost;
            float s1 = baseScale * 320.0 * detailBoost;
            float s2 = baseScale * 520.0 * detailBoost;

            float2 o0 = float2(z*0.33, -z*0.21);
            float2 o1 = float2(z*0.60,  z*0.15);
            float2 o2 = float2(-z*0.45, z*0.27);

            float p0 = lump4(uv*s0 + o0);
            float p1 = lump4(uv*s1 + o1);
            float p2 = lump4(uv*s2 + o2);

            // blend in a touch of fine value noise so it never tiles
            float vN = noise3(float3(uv*1.9, z*0.7));
            float c = 0.44*p0 + 0.34*p1 + 0.24*p2;
            c = mix(c, max(c, vN), 0.12);
            return pow(clamp(c,0.0,1.0), 1.06);
        }

        // macro clump mask (cheap)
        inline float macroMask2D(float2 uv){
            float w = noise3(float3(uv*0.62, 2.3));      // value-like
            float b = noise3(float3(uv*1.24, -1.7));
            float m = 0.6*w + 0.4*b;
            return smoothstep(0.42, 0.58, m);
        }

        inline float hg(float mu,float g){
            float g2=g*g;
            float denom=pow(max(1e-4,1.0+g2-2.0*g*mu),1.5);
            return (1.0-g2)/(4.0*3.14159265*denom);
        }

        // ===== fragment (5-slice analytic integration) =====
        #pragma body

        float2 uv = _surface.diffuseTexcoord*2.0 - 1.0;

        float2 halfs=float2(max(0.0001,impostorHalfW),max(0.0001,impostorHalfH));
        float s=max(halfs.x,halfs.y);
        float2 uvE=uv*halfs/s;

        // screen-space detail → larger on-screen → finer micro
        float px = max(fwidth(uvE.x), fwidth(uvE.y));
        float detailBoost = clamp(1.0 / max(0.0002, px * 28.0), 1.0, 10.0);

        // --- hide card rim with noisy feather + power falloff
        float r=length(uvE);
        float nEdge=noise3(float3(uvE*3.15,0.0));
        float rWobble=(nEdge*2.0-1.0)*edgeNoiseAmp;
        float rDist=r+rWobble;
        float cutR=1.0-clamp(edgeCut,0.0,0.49);
        if(rDist>=cutR){ discard_fragment(); }

        float featherW = clamp(edgeFeather * max(0.5, rimFeatherBoost), 0.0, 0.49);
        float featherR0=cutR-featherW;
        float rimSoft=smoothstep(featherR0,cutR,rDist);
        float interior=pow(clamp(1.0-rimSoft,0.0,1.0), max(1.0, rimFadePow));

        // irregular silhouette
        float sMask = macroMask2D(uvE*shapeScale + float2(shapeSeed*0.13, shapeSeed*0.29));
        sMask = smoothstep(shapeLo, shapeHi, sMask);
        sMask = pow(clamp(sMask,0.0,1.0), max(1.0, shapePow));

        float edgeMask = interior * sMask;
        if (edgeMask < 0.01) { discard_fragment(); }

        // core/rim behaviour
        float covLocal = mix(max(0.0,coverage-edgeErode),min(1.0,coverage+centreFill), edgeMask);
        float fillGain = mix(1.0, 1.0+centreFill, edgeMask);

        // slab
        float Lm = clamp(thickness, 0.50, 8.0);

        // --- 5-slice Simpson-like integration (no loop, very fast)
        const float wz[5]   = { -0.4, -0.2, 0.0, 0.2, 0.4 };
        const float wSim[5] = {  1.0,  4.0, 2.0, 4.0, 1.0 };
        float sumD = 0.0; float wSum = 0.0;

        for (int i=0;i<5;i++){
            float z = wz[i];
            float m = cauliflower(uvE, z, max(1e-4,puffScale), detailBoost);
            // enforce micro fill floor in the core; kills interior holes
            m = max(m, coreFloor * edgeMask);
            // macro clump
            float macro2 = macroMask2D(uvE*0.62 + float2(z*0.07, -z*0.05));
            float d = pow(clamp(m * macro2, 0.0, 1.0), 1.0) * edgeMask;
            sumD += wSim[i] * d;
            wSum += wSim[i];
        }
        float avgD = (wSum > 0.0) ? (sumD / wSum) : 0.0;

        // sun-only brightness: HG normalised (g=0 → 1)
        float3 sView = normalize(sunDirView);
        const float FOUR_PI = 12.566370614359172;
        float cosVS = clamp(-sView.z,-1.0,1.0);
        float FwdNorm = hg(cosVS, hgG) * FOUR_PI;

        // single-tap self-occlusion toward the sun (clumped field)
        float2 sunUV = normalize(abs(sView.x)+abs(sView.y)>1e-4 ? float2(sView.x,sView.y) : float2(0.0001,0.0001));
        float occ = 0.0;
        {
            float zo = 0.18;
            float mo = cauliflower(uvE + sunUV*0.22, zo, max(1e-4,puffScale), detailBoost);
            float macro2 = macroMask2D(uvE*0.62 + sunUV*0.12);
            occ = clamp(mo * macro2, 0.0, 1.0);
        }
        float shadow = 1.0 - clamp(occK * occ, 0.0, 0.85);

        // analytic transmittance through the slab
        float sigma = max(0.0, densityMul) * (0.10 * avgD + densBias);
        float alpha = 1.0 - exp(-sigma * Lm * fillGain);

        // colour (premultiplied white)
        float L = baseWhite * (hiGain * FwdNorm) * shadow;
        float3 C = float3(L * alpha);

        _output.color = float4(C, clamp(alpha, 0.0, 1.0));
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

        // Aspect UVs
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        // ===== ultra-dense defaults (10× again) but fast (no march) =====
        m.setValue(0.50 as CGFloat,  forKey: "stepMul")      // kept for compat
        m.setValue(9.00 as CGFloat,  forKey: "densityMul")   // huge extinction → integrates fast
        m.setValue(3.50 as CGFloat,  forKey: "thickness")
        m.setValue(0.00 as CGFloat,  forKey: "densBias")

        m.setValue(0.94 as CGFloat,  forKey: "coverage")
        m.setValue(0.0042 as CGFloat, forKey: "puffScale")   // very fine base (screen boost scales it)
        m.setValue(0.12 as CGFloat,  forKey: "edgeFeather")
        m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
        m.setValue(0.16 as CGFloat,  forKey: "edgeNoiseAmp")
        m.setValue(0.62 as CGFloat,  forKey: "edgeErode")
        m.setValue(0.78 as CGFloat,  forKey: "centreFill")
        m.setValue(1.03 as CGFloat,  forKey: "shapeScale")
        m.setValue(0.44 as CGFloat,  forKey: "shapeLo")
        m.setValue(0.72 as CGFloat,  forKey: "shapeHi")
        m.setValue(Float.random(in: 0...1000), forKey: "shapeSeed")

        m.setValue(1.90 as CGFloat,  forKey: "rimFeatherBoost")
        m.setValue(3.00 as CGFloat,  forKey: "rimFadePow")
        m.setValue(1.80 as CGFloat,  forKey: "shapePow")

        // no-hole core floor
        m.setValue(0.30 as CGFloat,  forKey: "coreFloor")

        // Sun-only white; isotropic
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.00 as CGFloat,  forKey: "hgG")
        m.setValue(1.00 as CGFloat,  forKey: "baseWhite")
        m.setValue(1.00 as CGFloat,  forKey: "hiGain")
        m.setValue(0.00 as CGFloat,  forKey: "edgeSoft")
        m.setValue(0.28 as CGFloat,  forKey: "microAmp")
        m.setValue(0.40 as CGFloat,  forKey: "occK")

        m.diffuse.contents  = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
