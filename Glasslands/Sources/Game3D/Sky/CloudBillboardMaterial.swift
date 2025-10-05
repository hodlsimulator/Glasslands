//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Single source of truth for the sprite material and its soft back-lighting.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {
    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    private static let marker = "/* VOL_IMPOSTOR_VSAFE_001 */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        let fragment = """
        \(marker)
        #pragma transparent
        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float  coverage;      // 0..1
        float  densityMul;    // 0.5..2.0
        float  stepMul;       // 0.7..1.5 (scales extinction)
        float  horizonLift;

        float  saturate1(float x) { return clamp(x, 0.0f, 1.0f); }
        float3 sat3(float3 v)     { return clamp(v, float3(0.0f), float3(1.0f)); }
        float  noise21(float2 p) {
            float n = sin(dot(p, float2(12.9898f, 78.233f))) * 43758.5453f;
            return fract(n);
        }
        float  phaseSchlick(float g, float mu) {
            float k = 1.55f * g - 0.55f * g * g;   // cheap, stable fit
            float d = 1.0f + k * (1.0f - mu);
            return (1.0f - k*k) / (d*d + 1e-4f);
        }

        #pragma body

        // Pre-sampled sprite alpha (NO texture sampling here).
        float2 uv  = _surface.diffuseTexcoord;
        float  a0  = saturate1(_output.color.a);
        if (a0 < 0.002f) { discard_fragment(); }

        // Billboard view ray – stable forward.
        float3 rd   = float3(0.0f, 0.0f, 1.0f);
        float3 sunV = normalize(sunDirView);
        float  mu   = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  phase= phaseSchlick(0.62f, mu);

        float  c      = saturate1(coverage);
        float  thresh = clamp(0.56f - 0.36f * c, 0.20f, 0.62f);
        float  soft   = 0.25f;

        float  q      = clamp(stepMul, 0.7f, 1.5f);
        float  kSigma = 0.14f * q / 8.0f * densityMul;

        float  T  = 1.0f;
        float3 S  = float3(0.0f, 0.0f, 0.0f);

        // --- 8 fixed slices, fully inlined (no loops, no samplers) ---
        {
            float h=0.0625f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.1875f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.3125f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.4375f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.5625f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.6875f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.8125f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }{
            float h=0.9375f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float j=(noise21(uv*19.0f+float2(h,h*1.7f))-0.5f)*0.08f; float bias=(h-0.5f)*0.10f+j;
            float d=smoothstep(thresh-soft,thresh+soft,saturate1(a0+bias));
            float powder=1.0f-exp(-2.0f*d); float dens=max(0.0f,d*env)*1.15f; float a=exp(-kSigma*dens);
            float sliceT=T*(1.0f-a); S+=sunTint*(phase*(0.40f+0.60f*powder))*sliceT; T*=a;
        }

        // Subtle horizon lift
        S += float3(horizonLift * (1.0f - uv.y) * 0.22f);

        float alphaOut = (1.0f - T) * a0;
        _output.color = float4(sat3(S) * alphaOut, clamp(alphaOut, 0.0f, 1.0f));
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        m.setValue(SCNVector3(0, 0, 1),          forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,              forKey: "coverage")
        m.setValue(1.10 as CGFloat,              forKey: "densityMul")
        m.setValue(1.00 as CGFloat,              forKey: "stepMul")
        m.setValue(0.16 as CGFloat,              forKey: "horizonLift")
        return m
    }

    // Helper so other files can check the marker if needed
    static var volumetricMarker: String { marker }
}
