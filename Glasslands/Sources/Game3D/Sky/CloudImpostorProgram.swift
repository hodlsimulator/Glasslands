//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric billboard impostor using true 3D density (no laminated 2D).
//  Sun “paints” highlights and soft self-shadow. Unrolled 5-tap thickness trace.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        // ===== uniforms (one per line; no comments) =====
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;
        float densityMul;
        float thickness;
        float densBias;
        float coverage;
        float puffScale;
        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;
        float rimFeatherBoost;
        float rimFadePow;
        float3 sunDirView;
        float hgG;
        float baseWhite;
        float hiGain;
        float occK;

        // ===== helpers =====
        #pragma declarations
        inline float hash1(float n){ return fract(sin(n) * 43758.5453123); }

        inline float noise3(float3 x){
            float3 p=floor(x), f=x-p;
            f=f*f*(3.0-2.0*f);
            const float3 off=float3(1.0,57.0,113.0);
            float n=dot(p,off);
            float n000=hash1(n+0.0), n100=hash1(n+1.0), n010=hash1(n+57.0), n110=hash1(n+58.0);
            float n001=hash1(n+113.0),n101=hash1(n+114.0),n011=hash1(n+170.0),n111=hash1(n+171.0);
            float nx00=mix(n000,n100,f.x), nx10=mix(n010,n110,f.x);
            float nx01=mix(n001,n101,f.x), nx11=mix(n011,n111,f.x);
            float nxy0=mix(nx00,nx10,f.y), nxy1=mix(nx01,nx11,f.y);
            return mix(nxy0,nxy1,f.z);
        }

        // Billowy 3D FBM with a touch of domain warp → cauliflower
        inline float fbm3_billow(float3 p){
            float a=0.0, w=0.55;
            float3 q=p + (noise3(p*0.33+float3(2.1,-1.7,0.9))*2.0-1.0)*0.35;
            for(int i=0;i<4;++i){
                float n=noise3(q);
                a += w * (1.0 - abs(n*2.0 - 1.0));
                q *= 2.05; w *= 0.52;
            }
            return clamp(a,0.0,1.0);
        }

        inline float hg(float mu,float g){
            float g2=g*g;
            float denom=pow(max(1e-4,1.0+g2-2.0*g*mu),1.5);
            return (1.0-g2)/(4.0*3.14159265*denom);
        }

        // 3D density sample at uvE, depth z in [-.5,.5]
        inline float sampleD3(float2 uvE, float z, float baseScale, float edgeMask, float coreFloorK){
            float3 p = float3(uvE * (baseScale*360.0), z * (baseScale*420.0));

            // three soft “blobs” → lumpy core
            float3 s0=float3( 0.00,  0.00,  0.00);
            float3 s1=float3( 0.38, -0.18,  0.22);
            float3 s2=float3(-0.34,  0.26, -0.28);

            float c0 = exp(-dot(p - s0, p - s0) * 0.85);
            float c1 = exp(-dot(p - s1, p - s1) * 0.85);
            float c2 = exp(-dot(p - s2, p - s2) * 0.85);
            float core = clamp((c0*0.55 + c1*0.45 + c2*0.40), 0.0, 1.0);

            float micro = fbm3_billow(p);
            float d = clamp(core*0.75 + micro*0.55, 0.0, 1.0);
            d = max(d * edgeMask, coreFloorK * edgeMask);
            return d;
        }

        // ===== fragment =====
        #pragma body

        // Aspect-correct sprite space in [-1,1]
        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;
        float2 halfs = float2(max(0.0001,impostorHalfW), max(0.0001,impostorHalfH));
        float s = max(halfs.x, halfs.y);
        float2 uvE = uv * halfs / s;

        // Pixel footprint → stabilise details
        float px = max(fwidth(uvE.x), fwidth(uvE.y));
        float detailBoost = clamp(1.0/max(0.0002,px*28.0),1.0,8.0);

        // Noisy circular cut with feather to hide the card
        float r = length(uvE);
        float nEdge = noise3(float3(uvE*3.15, 0.0));
        float rWobble = (nEdge*2.0-1.0) * edgeNoiseAmp;
        float rDist = r + rWobble;

        float cutR = 1.0 - clamp(edgeCut, 0.0, 0.49);
        if (rDist >= cutR) { discard_fragment(); }

        float featherW = clamp(edgeFeather * max(0.5, rimFeatherBoost), 0.0, 0.49);
        float rimSoft = smoothstep(cutR - featherW, cutR, rDist);
        float interior = pow(clamp(1.0 - rimSoft, 0.0, 1.0), max(1.0, rimFadePow));

        float edgeMask = interior;
        if (edgeMask < 0.01) { discard_fragment(); }

        // Params
        float Lm = clamp(thickness, 0.50, 8.0);
        float baseScale = max(1e-4, puffScale) * detailBoost;
        float coreFloorK = clamp(0.20 + 0.22*coverage, 0.0, 0.6);

        // 5 fixed z samples (Simpson weights 1,4,2,4,1)
        float d0 = sampleD3(uvE, -0.40, baseScale, edgeMask, coreFloorK);
        float d1 = sampleD3(uvE, -0.20, baseScale, edgeMask, coreFloorK);
        float d2 = sampleD3(uvE,  0.00, baseScale, edgeMask, coreFloorK);
        float d3 = sampleD3(uvE,  0.20, baseScale, edgeMask, coreFloorK);
        float d4 = sampleD3(uvE,  0.40, baseScale, edgeMask, coreFloorK);
        float avgD = (d0 + 4.0*d1 + 2.0*d2 + 4.0*d3 + d4) * (1.0/12.0);

        // Sun direction in view space
        float3 sView = normalize(sunDirView);

        // Approximate normal from density slope
        float2 sunUV = normalize(abs(sView.x)+abs(sView.y)>1e-4 ? float2(sView.x,sView.y) : float2(0.0001,0.0001));
        float eps = 0.06;
        float sdP = sampleD3(uvE + sunUV*eps,  0.0, baseScale, edgeMask, coreFloorK);
        float sdM = sampleD3(uvE - sunUV*eps,  0.0, baseScale, edgeMask, coreFloorK);
        float gradS = (sdP - sdM) / (2.0*eps);
        float gradZ = (d4 - d0) / 0.8;
        float3 approxN = normalize(float3(sunUV * (-gradS), -gradZ) + float3(0.0,0.0,1e-4));

        // Lighting: sun paints the cloud
        float NdotL = clamp(dot(approxN, -sView), 0.0, 1.0);
        const float FOUR_PI = 12.566370614359172;
        float cosVS = clamp(-sView.z, -1.0, 1.0);
        float FwdNorm = hg(cosVS, hgG) * FOUR_PI;

        // Two-tap self-shadow towards sun
        float occ1 = sampleD3(uvE + sunUV*0.20,  0.15, baseScale, edgeMask, coreFloorK);
        float occ2 = sampleD3(uvE + sunUV*0.38,  0.28, baseScale, edgeMask, coreFloorK);
        float occ = 0.65*occ1 + 0.35*occ2;
        float shadow = exp(-clamp(occK, 0.0, 1.2) * occ);

        // Beer–Lambert through slab → alpha
        float sigma = max(0.0, densityMul) * (0.12*avgD + densBias);
        float alpha = clamp(1.0 - exp(-sigma * Lm), 0.0, 1.0);

        // White under sun (no ambient)
        float L = baseWhite * (0.35 + 0.65*NdotL) * (hiGain*FwdNorm) * shadow;
        float3 C = float3(L * alpha);
        _output.color = float4(C, alpha);
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

        // aspect-correct UVs
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        // Safe, dense defaults
        m.setValue(8.00 as CGFloat, forKey: "densityMul")
        m.setValue(3.20 as CGFloat, forKey: "thickness")
        m.setValue(0.00 as CGFloat, forKey: "densBias")
        m.setValue(0.92 as CGFloat, forKey: "coverage")

        m.setValue(0.0042 as CGFloat, forKey: "puffScale")
        m.setValue(0.12  as CGFloat, forKey: "edgeFeather")
        m.setValue(0.06  as CGFloat, forKey: "edgeCut")
        m.setValue(0.16  as CGFloat, forKey: "edgeNoiseAmp")
        m.setValue(1.90  as CGFloat, forKey: "rimFeatherBoost")
        m.setValue(2.80  as CGFloat, forKey: "rimFadePow")

        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.55  as CGFloat, forKey: "hgG")       // mild forward bias
        m.setValue(1.00  as CGFloat, forKey: "baseWhite")
        m.setValue(1.00  as CGFloat, forKey: "hiGain")
        m.setValue(0.40  as CGFloat, forKey: "occK")

        m.diffuse.contents  = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
