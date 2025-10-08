//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Dense, round cauliflower vapour with hidden billboard rims.
//  Sun-only white. Fast path: 5 fixed z-samples (unrolled), no per-pixel loops.
//  Important: macro gating is optional (default 0) so a sprite doesn't break into islands.
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

        float stepMul;        // compat only (not used)
        float densityMul;     // extinction strength
        float thickness;      // slab depth
        float densBias;

        float coverage;       // 0..1 fullness
        float puffScale;      // micro scale
        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;
        float shapeScale;
        float shapeLo;
        float shapeHi;
        float shapeSeed;

        float rimFeatherBoost;
        float rimFadePow;
        float shapePow;

        // NEW: weight of macro gating inside the sprite (0 = off, 1 = fully on)
        float macroWeight;

        float3 sunDirView;
        float hgG;
        float baseWhite;
        float hiGain;
        float edgeSoft;       // unused (kept for compat)
        float microAmp;       // unused in this path (kept for compat)
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

        // 2-octave billowy cellular → cauliflower
        inline float puffFBM2(float2 x){
            float a=0.0,w=0.62,s=1.0;
            float v=1.0-clamp(worley2(x*s),0.0,1.0); a+=v*w; s*=2.03; w*=0.55;
            v=1.0-clamp(worley2(x*s),0.0,1.0);       a+=v*w;
            return clamp(a,0.0,1.0);
        }

        inline float macroMask2D(float2 uv){
            float w=noise3(float3(uv*0.62, 2.3));
            float b=noise3(float3(uv*1.24,-1.7));
            float m=0.6*w+0.4*b;
            return smoothstep(0.42,0.58,m);
        }

        inline float hg(float mu,float g){
            float g2=g*g;
            float denom=pow(max(1e-4,1.0+g2-2.0*g*mu),1.5);
            return (1.0-g2)/(4.0*3.14159265*denom);
        }

        inline float sampleD(float2 uvE,float z,float baseScale,float detailBoost,float edgeMask,float coreFloorK,float macroW){
            float2 o0=float2(z*0.33,-z*0.21);
            float2 o1=float2(z*0.60, z*0.15);
            float2 o2=float2(-z*0.45, z*0.27);
            float s0=baseScale*180.0*detailBoost;
            float s1=baseScale*320.0*detailBoost;
            float s2=baseScale*520.0*detailBoost;
            float p0=puffFBM2(uvE*s0 + o0);
            float p1=puffFBM2(uvE*s1 + o1);
            float p2=puffFBM2(uvE*s2 + o2);
            float micro=0.44*p0 + 0.34*p1 + 0.24*p2;
            // small core floor so we don't get pinholes
            micro=max(micro, coreFloorK*edgeMask);

            // optional macro gating (default 0 → does nothing)
            float macro = macroMask2D(uvE*0.62 + float2(z*0.07,-z*0.05));
            float gate  = mix(1.0, macro, clamp(macroW, 0.0, 1.0));

            return clamp(micro * gate, 0.0, 1.0) * edgeMask;
        }

        // ===== fragment =====
        #pragma body

        float2 uv=_surface.diffuseTexcoord*2.0-1.0;

        float2 halfs=float2(max(0.0001,impostorHalfW),max(0.0001,impostorHalfH));
        float s=max(halfs.x,halfs.y);
        float2 uvE=uv*halfs/s;

        // screen-space detail boost
        float px=max(fwidth(uvE.x),fwidth(uvE.y));
        float detailBoost=clamp(1.0/max(0.0002,px*28.0),1.0,8.0);

        // hide card with noisy rim + power falloff
        float r=length(uvE);
        float nEdge=noise3(float3(uvE*3.15,0.0));
        float rWobble=(nEdge*2.0-1.0)*edgeNoiseAmp;
        float rDist=r+rWobble;
        float cutR=1.0-clamp(edgeCut,0.0,0.49);
        if(rDist>=cutR){ discard_fragment(); }

        float featherW=clamp(edgeFeather*max(0.5,rimFeatherBoost),0.0,0.49);
        float featherR0=cutR-featherW;
        float rimSoft=smoothstep(featherR0,cutR,rDist);
        float interior=pow(clamp(1.0-rimSoft,0.0,1.0), max(1.0,rimFadePow));

        float sMask=macroMask2D(uvE*shapeScale + float2(shapeSeed*0.13,shapeSeed*0.29));
        sMask=smoothstep(shapeLo,shapeHi,sMask);
        sMask=pow(clamp(sMask,0.0,1.0), max(1.0,shapePow));
        float edgeMask=interior*sMask;
        if(edgeMask<0.01){ discard_fragment(); }

        float Lm=clamp(thickness,0.50,8.0);
        float baseScale=max(1e-4,puffScale);

        // derive small core floor outside helpers; pass it in
        float coreFloorK = clamp(0.25 + 0.18*coverage, 0.0, 0.6);
        float macroW = clamp(macroWeight, 0.0, 1.0);          // default 0 → no sprite fragmentation

        // 5 fixed z-samples (unrolled): Simpson weights 1,4,2,4,1 → /12
        float d0=sampleD(uvE,-0.4,baseScale,detailBoost,edgeMask,coreFloorK,macroW);
        float d1=sampleD(uvE,-0.2,baseScale,detailBoost,edgeMask,coreFloorK,macroW);
        float d2=sampleD(uvE, 0.0,baseScale,detailBoost,edgeMask,coreFloorK,macroW);
        float d3=sampleD(uvE, 0.2,baseScale,detailBoost,edgeMask,coreFloorK,macroW);
        float d4=sampleD(uvE, 0.4,baseScale,detailBoost,edgeMask,coreFloorK,macroW);
        float avgD=(d0 + 4.0*d1 + 2.0*d2 + 4.0*d3 + d4) * (1.0/12.0);

        // sun-only white
        float3 sView=normalize(sunDirView);
        const float FOUR_PI=12.566370614359172;
        float cosVS=clamp(-sView.z,-1.0,1.0);
        float FwdNorm=hg(cosVS,hgG)*FOUR_PI;

        // single occlusion tap towards sun
        float2 sunUV=normalize(abs(sView.x)+abs(sView.y)>1e-4 ? float2(sView.x,sView.y) : float2(0.0001,0.0001));
        float occ=sampleD(uvE + sunUV*0.22, 0.18, baseScale, detailBoost, edgeMask, coreFloorK, macroW);
        float shadow=1.0 - clamp(occK*occ, 0.0, 0.85);

        // Beer–Lambert through slab
        float sigma=max(0.0,densityMul)*(0.12*avgD + densBias);
        float alpha=clamp(1.0 - exp(-sigma*Lm), 0.0, 1.0);

        float L=baseWhite*(hiGain*FwdNorm)*shadow;
        float3 C=float3(L*alpha);

        _output.color=float4(C,alpha);
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

        // dense but safe defaults
        m.setValue(0.50 as CGFloat,  forKey: "stepMul")
        m.setValue(7.00 as CGFloat,  forKey: "densityMul")
        m.setValue(3.00 as CGFloat,  forKey: "thickness")
        m.setValue(0.00 as CGFloat,  forKey: "densBias")

        m.setValue(0.90 as CGFloat,  forKey: "coverage")
        m.setValue(0.0045 as CGFloat, forKey: "puffScale")
        m.setValue(0.12 as CGFloat,  forKey: "edgeFeather")
        m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
        m.setValue(0.14 as CGFloat,  forKey: "edgeNoiseAmp")
        m.setValue(1.03 as CGFloat,  forKey: "shapeScale")
        m.setValue(0.40 as CGFloat,  forKey: "shapeLo")
        m.setValue(0.68 as CGFloat,  forKey: "shapeHi")
        m.setValue(Float.random(in: 0...1000), forKey: "shapeSeed")

        m.setValue(1.70 as CGFloat,  forKey: "rimFeatherBoost")
        m.setValue(2.60 as CGFloat,  forKey: "rimFadePow")
        m.setValue(1.50 as CGFloat,  forKey: "shapePow")

        // macro gating default OFF to avoid sprite fragmentation
        m.setValue(0.00 as CGFloat,  forKey: "macroWeight")

        // sun-only white; isotropic
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.00 as CGFloat,  forKey: "hgG")
        m.setValue(1.00 as CGFloat,  forKey: "baseWhite")
        m.setValue(1.00 as CGFloat,  forKey: "hiGain")
        m.setValue(0.00 as CGFloat,  forKey: "edgeSoft")
        m.setValue(0.40 as CGFloat,  forKey: "occK")

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
