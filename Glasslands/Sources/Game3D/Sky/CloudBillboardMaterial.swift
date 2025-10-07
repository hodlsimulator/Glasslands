//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Analytic white billboards (no texture sampling) with sun-only lighting.
//  – Helper functions are defined BEFORE `#pragma arguments` (required by SceneKit).
//  – `#pragma arguments` contains ONLY declarations (no comments).
//  – Alpha uses Beer–Lambert on an analytic thickness field.
//  – Two-tap self-occlusion along sun direction adds soft texture.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_095_WHITE_SUN_ONLY_ALPHA */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial { makeAnalyticWhitePuff() }

    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        let fragment = """
        \(volumetricMarker)

        // ---- helpers (must be before #pragma arguments in SceneKit shader modifiers) ----
        float fractf(float x){ return x - floor(x); }

        float hash21(float2 p){
            return fractf(sin(dot(p, float2(127.1,311.7))) * 43758.5453123);
        }

        float vnoise(float2 p){
            float2 i = floor(p);
            float2 f = p - i;
            float a = hash21(i);
            float b = hash21(i + float2(1,0));
            float c = hash21(i + float2(0,1));
            float d = hash21(i + float2(1,1));
            float2 u = f*f*(3.0 - 2.0*f);
            return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
        }

        float fbm3(float2 p){
            float a = 0.0; float w = 0.5;
            a += vnoise(p) * w;           p = p*2.02 + 19.19; w *= 0.5;
            a += vnoise(p) * w;           p = p*2.02 + 19.19; w *= 0.5;
            a += vnoise(p) * w;
            return a;
        }

        float2 fieldAt(float2 uv, float edgeSoft, float densBias, float microAmp){
            float2 c = (uv - float2(0.5, 0.5)) * 2.0;
            float  r = length(c);
            float  w = max(1e-5, fwidth(r)) * edgeSoft;
            float  rim = smoothstep(1.0 - w, 1.0 + w, r); // 0 center, 1 rim
            float  edgeMask = 1.0 - rim;                  // 1 inside, 0 outside
            float  und = 1.0 + microAmp * (fbm3(uv * 6.0 + float2(3.1, -2.7)) - 0.5) * 1.6;
            float  dens = pow(edgeMask, 1.1) * und * densBias;
            return float2(max(0.0, dens), clamp(edgeMask, 0.0, 1.0));
        }

        float selfOcc(float2 uv, float2 sun2, float edgeSoft, float densBias, float microAmp, float occK){
            float2 f1 = fieldAt(uv + sun2 * 0.10, edgeSoft, densBias, microAmp);
            float2 f2 = fieldAt(uv + sun2 * 0.22, edgeSoft, densBias, microAmp);
            float   occ = exp(-occK * (f1.x * 0.6 + f2.x * 0.4));
            return clamp(occ, 0.0, 1.0);
        }

        #pragma arguments
        float3 sunDirView;
        float  hgG;
        float  baseWhite;
        float  hiGain;
        float  edgeSoft;
        float  opaK;
        float  densBias;
        float  microAmp;
        float  occK
        #pragma body

        float2 uv = _surface.diffuseTexcoord;

        float2 f = fieldAt(uv, edgeSoft, densBias, microAmp);
        float  dens = f.x;
        float  edgeMask = f.y;
        if (edgeMask < 0.002){ discard_fragment(); }

        float3 V = normalize(-_surface.view);
        float3 S = normalize(sunDirView);
        float  mu = clamp(dot(V,S), -1.0, 1.0);

        float g  = clamp(hgG, 0.0, 0.95);
        float g2 = g*g;
        float hg = (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0*g*mu, 1.5));

        float2 sun2 = normalize(float2(S.x, S.y));
        if (abs(sun2.x) + abs(sun2.y) < 1e-3) sun2 = float2(0.7071, 0.7071);
        float occ = selfOcc(uv, sun2, edgeSoft, densBias, microAmp, occK);

        float L = clamp(baseWhite + hiGain * hg * occ, 0.0, 1.0);
        float3 C = float3(L);

        float alpha = 1.0 - exp(-opaK * dens);
        alpha *= edgeMask;

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
        m.shaderModifiers = [.fragment: fragment]

        // Safe defaults (engine updates at runtime)
        m.setValue(SCNVector3(0, 0, 1), forKey: "sunDirView")
        m.setValue(0.56 as CGFloat,     forKey: "hgG")
        m.setValue(0.70 as CGFloat,     forKey: "baseWhite")
        m.setValue(0.65 as CGFloat,     forKey: "hiGain")
        m.setValue(0.06 as CGFloat,     forKey: "edgeSoft")
        m.setValue(1.90 as CGFloat,     forKey: "opaK")
        m.setValue(1.00 as CGFloat,     forKey: "densBias")
        m.setValue(0.18 as CGFloat,     forKey: "microAmp")
        m.setValue(1.10 as CGFloat,     forKey: "occK")
        return m
    }
}
