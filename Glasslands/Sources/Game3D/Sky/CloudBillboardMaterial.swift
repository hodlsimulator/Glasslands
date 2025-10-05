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
    static func makeVolumetricTemplate() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        // Built-in diffuse texture bindings (SceneKit provides these).
        #pragma arguments
        texture2d<float> u_diffuseTexture;
        sampler          u_diffuseTextureSampler;

        float3 sunDirView;
        float3 sunTint;

        float  coverage;      // 0..1 → threshold bias
        float  densityMul;    // overall density
        float  stepMul;       // 0.7..1.5 quality/perf
        float  horizonLift;   // small lift near horizon

        float  saturate1(float x) { return clamp(x, 0.0, 1.0); }
        float3 saturate3(float3 v){ return clamp(v, float3(0.0), float3(1.0)); }
        float  lerp1(float a,float b,float t){ return a + (b - a) * t; }
        float  hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            float h = dot(p, p + float2(78.233, 78.233));
            p += float2(h, h);
            return fract(p.x * p.y);
        }
        float  hgPhase(float g, float mu) {
            float gg = g * g;
            return (1.0 - gg) / pow(1.0 + gg - 2.0*g*mu, 1.5);
        }

        #pragma body

        // Sprite UV
        float2 uv = clamp(_surface.diffuseTexcoord, 0.002, 0.998);

        // Sample the built-in diffuse (alpha drives the silhouette).
        float a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv).a;
        if (a0 < 0.002) { discard_fragment(); }

        float3 rd   = normalize(-_surface.view);
        float3 sunV = normalize(sunDirView);

        // March settings
        const int Nbase = 18;
        int   N  = (int)round(clamp(stepMul, 0.7, 1.5) * (float)Nbase);  // 13..27
        float T  = 1.0;                         // transmittance
        float3 S = float3(0.0, 0.0, 0.0);       // integrated single scattering

        // Phase (single scatter)
        float g  = 0.62;
        float mu = clamp(dot(rd, sunV), -1.0, 1.0);
        float phase = clamp(hgPhase(g, mu), 0.0, 5.0);

        // Threshold from coverage; lenient so puffs appear.
        float thresh   = clamp(0.56 - 0.36 * saturate1(coverage), 0.20, 0.62);
        float softness = 0.25;

        // Short thickness; emulate parallax via height bias + jitter.
        for (int i = 0; i < N; ++i) {
            float t = (float(i) + 0.5) / float(N);         // 0..1 thickness
            float h = t;                                   // vertical factor

            // Height envelope – fuller in the middle, thins near top/bottom.
            float env = smoothstep(0.06, 0.40, h) * (1.0 - smoothstep(0.58, 0.98, h));

            // Bias the silhouette across thickness to fake parallax, add mild jitter.
            float jitter = (hash21(uv * 19.0 + float2(t, t*1.7)) - 0.5) * 0.08;
            float bias   = (h - 0.5) * 0.10 + jitter;

            float d = smoothstep(thresh - softness, thresh + softness, saturate1(a0 + bias));

            // Powder effect to avoid dull greys in thicker areas.
            float powder = 1.0 - exp(-2.0 * d);

            // Per-slice extinction (Beer–Lambert, thin-slice).
            float dens  = max(0.0, d * env) * densityMul * 1.15;
            float sigma = 1.05 / float(N);
            float A = sigma * dens;
            float a = exp(-A);
            float sliceT = T * (1.0 - a);

            // Single scattering towards the eye (premultiplied).
            float3 scatCol = sunTint * (phase * (0.40 + 0.60 * powder));
            S += scatCol * sliceT;

            T *= a;
            if (T < 0.02) { break; }
        }

        // Gentle lift near horizon so sprites don't sink into the background gradient.
        S += float3(horizonLift * (1.0 - uv.y) * 0.22);

        // Premultiplied output with sprite alpha gate.
        float alphaOut = (1.0 - T) * a0;
        _output.color = float4(saturate3(S), alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.transparencyMode = .aOne       // premultiplied from shader
        m.blendMode = .alpha
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        m.shaderModifiers = [.fragment: fragment]

        // Sprite sampling setup (keeps edges clean)
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Sun defaults; kept in sync by your existing sun update
        m.setValue(SCNVector3(0, 0, 1),          forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")

        // Tuning
        m.setValue(0.42 as CGFloat,              forKey: "coverage")
        m.setValue(1.10 as CGFloat,              forKey: "densityMul")
        m.setValue(1.00 as CGFloat,              forKey: "stepMul")
        m.setValue(0.16 as CGFloat,              forKey: "horizonLift")

        return m
    }
}
