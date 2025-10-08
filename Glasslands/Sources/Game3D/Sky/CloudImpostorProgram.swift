//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Dense, clumped cauliflower vapour with hidden billboard rims.
//  Sun-only white; adaptive steps; screen-space detail boost.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {

        let frag = """
        #pragma transparent

        // ===== uniforms (SceneKit: one per line) =====
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;

        float stepMul;
        float densityMul;
        float thickness;
        float densBias;

        float coverage;
        float puffScale;
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

        float3 sunDirView;
        float hgG;
        float baseWhite;
        float hiGain;
        float edgeSoft;   // unused for lighting (kept for compat)
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

        inline float worley2(float2 x){
            float2 i=floor(x), f=x-i; float d=1e9;
            for(int y=-1;y<=1;++y) for(int xk=-1;xk<=1;++xk){
                float2 g=float2(xk,y);
                float2 o=float2(hash12(i+g),hash12(i+g+19.7));
                float2 r=g+o-f; d=min(d,dot(r,r));
            }
            return sqrt(max(d,0.0));
        }

        inline float puffFBM2(float2 x){
            float a=0.0,w=0.62,s=1.0;
            float v=1.0-clamp(worley2(x*s),0.0,1.0); a+=v*w; s*=2.03; w*=0.55;
            v=1.0-clamp(worley2(x*s),0.0,1.0);       a+=v*w;
            return clamp(a,0.0,1.0);
        }

        // 3 layered cauliflower micro field (scales & z phases)
        inline float cauliflowerLayers(float2 uv, float z, float baseScale, float detailBoost){
            float s0 = baseScale * 180.0 * detailBoost;
            float s1 = baseScale * 300.0 * detailBoost;
            float s2 = baseScale * 520.0 * detailBoost;

            float2 o0 = float2(z*0.33, -z*0.21);
            float2 o1 = float2(z*0.60,  z*0.15);
            float2 o2 = float2(-z*0.45, z*0.27);

            float p0 = puffFBM2(uv*s0 + o0);
            float p1 = puffFBM2(uv*s1 + o1);
            float p2 = puffFBM2(uv*s2 + o2);

            float c = 0.45*p0 + 0.35*p1 + 0.25*p2;
            return pow(clamp(c,0.0,1.0), 1.08);
        }

        inline float macroMask2D(float2 uv){ return 1.0 - clamp(worley2(uv*1.32), 0.0, 1.0); }

        // Soft OR for clumping: 1 - Π(1 - d_i)
        inline float softOr3(float d0, float d1, float d2){
            return 1.0 - (1.0 - d0)*(1.0 - d1)*(1.0 - d2);
        }

        inline float hg(float mu,float g){
            float g2=g*g;
            float denom=pow(max(1e-4,1.0+g2-2.0*g*mu),1.5);
            return (1.0-g2)/(4.0*3.14159265*denom);
        }

        // ===== fragment =====
        #pragma body

        float2 uv=_surface.diffuseTexcoord*2.0-1.0;

        float2 halfs=float2(max(0.0001,impostorHalfW),max(0.0001,impostorHalfH));
        float s=max(halfs.x,halfs.y);
        float2 uvE=uv*halfs/s;

        // Screen-space detail: larger on-screen → finer micro
        float px = max(fwidth(uvE.x), fwidth(uvE.y));
        float detailBoost = clamp(1.0 / max(0.0002, px * 28.0), 1.0, 10.0);

        // --- Rim kill (hide the card) ---
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

        float sMask=macroMask2D(uvE*shapeScale + float2(shapeSeed*0.13, shapeSeed*0.29));
        sMask = smoothstep(shapeLo, shapeHi, sMask);
        sMask = pow(clamp(sMask,0.0,1.0), max(1.0, shapePow));

        float edgeMask=interior*sMask;
        if (edgeMask < 0.01) { discard_fragment(); }

        // Fuller centres / eroded rims
        float covLocal=mix(max(0.0,coverage-edgeErode),min(1.0,coverage+centreFill),edgeMask);
        float fillGain=mix(1.0,1.0+centreFill,edgeMask);

        // Slab & adaptive steps (more in centre)
        float  Lm=clamp(thickness,0.50,8.0);
        int    Nbase = 18;
        float  qSteps = mix(0.70, 1.00, edgeMask);
        int    N  = clamp(int(round(float(Nbase) * clamp(stepMul,0.35,1.20) * qSteps)), 8, 28);
        float  dt = Lm/float(N);

        float  j = fract(sin(dot(uvE,float2(12.9898,78.233)))*43758.5453);
        float  t = (0.35+0.5*j)*dt;

        float3 sView=normalize(sunDirView);
        const float FOUR_PI=12.566370614359172;
        float cosVS = clamp(-sView.z,-1.0,1.0);
        float FwdNorm = hg(cosVS, hgG) * FOUR_PI;   // g=0 ⇒ 1.0

        float  T=1.0;
        float3 C=float3(0.0);

        // Macro clump once per fragment
        float macro2 = macroMask2D(uvE*0.62);

        // Neighbour radius in impostor UVs (screen-space based)
        float neighR = clamp(px * 24.0, 0.006, 0.030);
        const float2 d1 = float2( 0.8660254,  0.5);
        const float2 d2 = float2(-0.5,       0.8660254);
        const float2 d3 = float2(-0.3660254,-0.930);

        for(int i=0;i<N && T>0.004;++i){
            float z=-0.5*Lm + t;

            // Centre micro (3 layers)
            float m0 = cauliflowerLayers(uvE, z, max(1e-4,puffScale), detailBoost);

            // Clamp the gaps by “soft OR” with two neighbour taps (cheap)
            float sCoarse = max(1e-4,puffScale) * 260.0 * detailBoost;
            float2 o1 = float2(z*0.60,  z*0.15);
            float2 o2 = float2(-z*0.45, z*0.27);
            float mA = puffFBM2((uvE + d1*neighR)*sCoarse + o1);
            float mB = puffFBM2((uvE + d2*neighR)*sCoarse + o2);
            float mClump = softOr3(m0, mA, mB);

            // Apply macro clumps and rim mask
            float d = pow(clamp(mClump * macro2, 0.0, 1.0), 1.0) * edgeMask;

            if(d>0.0005){
                // one-tap self-occlusion in sun direction
                float2 sunUV = normalize(abs(sView.x)+abs(sView.y)>1e-4 ? float2(sView.x,sView.y) : float2(0.0001,0.0001));
                float  zOcc  = z + sView.z*0.22;
                float  oA    = puffFBM2((uvE + sunUV*0.22 + d1*neighR)*sCoarse + o1);
                float  oB    = puffFBM2((uvE + sunUV*0.22 + d2*neighR)*sCoarse + o2);
                float  o0    = cauliflowerLayers(uvE + sunUV*0.22, zOcc, max(1e-4,puffScale), detailBoost);
                float  occ   = softOr3(o0, oA, oB) * macro2;
                float  shadow= 1.0 - clamp(occK*occ, 0.0, 0.85);

                float sigma = max(0.0, densityMul) * (0.10*d + densBias);
                float aStep = 1.0 - exp(-sigma * dt * fillGain);

                float l = baseWhite * (hiGain * FwdNorm) * shadow; // sun-only white
                C += (l * aStep) * T;
                T *= (1.0 - aStep);

                if (T < 0.08) { break; } // super-dense → early exit
            }

            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        _output.color = float4(C, alpha); // premultiplied
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

        // Aspect-correct UVs
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        // Dense + clumped defaults (fast via early-outs/adaptive steps)
        m.setValue(0.46 as CGFloat,  forKey: "stepMul")
        m.setValue(3.60 as CGFloat,  forKey: "densityMul")
        m.setValue(3.00 as CGFloat,  forKey: "thickness")
        m.setValue(0.00 as CGFloat,  forKey: "densBias")

        m.setValue(0.92 as CGFloat,  forKey: "coverage")
        m.setValue(0.0048 as CGFloat, forKey: "puffScale")
        m.setValue(0.12 as CGFloat,  forKey: "edgeFeather")
        m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
        m.setValue(0.16 as CGFloat,  forKey: "edgeNoiseAmp")
        m.setValue(0.58 as CGFloat,  forKey: "edgeErode")
        m.setValue(0.72 as CGFloat,  forKey: "centreFill")
        m.setValue(1.03 as CGFloat,  forKey: "shapeScale")
        m.setValue(0.44 as CGFloat,  forKey: "shapeLo")
        m.setValue(0.72 as CGFloat,  forKey: "shapeHi")
        m.setValue(Float.random(in: 0...1000), forKey: "shapeSeed")

        m.setValue(1.80 as CGFloat,  forKey: "rimFeatherBoost")
        m.setValue(3.00 as CGFloat,  forKey: "rimFadePow")
        m.setValue(1.80 as CGFloat,  forKey: "shapePow")

        // Sun-only white; isotropic
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.00 as CGFloat,  forKey: "hgG")
        m.setValue(1.00 as CGFloat,  forKey: "baseWhite")
        m.setValue(1.00 as CGFloat,  forKey: "hiGain")
        m.setValue(0.00 as CGFloat,  forKey: "edgeSoft")
        m.setValue(0.30 as CGFloat,  forKey: "microAmp")
        m.setValue(0.40 as CGFloat,  forKey: "occK")

        m.diffuse.contents  = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
