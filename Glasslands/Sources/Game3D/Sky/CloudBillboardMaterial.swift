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

    // Marker for logs/verification.
    private static let marker = "/* VOL_IMPOSTOR_VSAFE_009_ROUND_DENSE */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        // Pure white cumulus puffs; centre-weighted; soft rims; premultiplied.
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;      // kept for compatibility
        float  coverage;     // 0..1
        float  densityMul;   // 0.5..2.0
        float  stepMul;      // 0.7..1.5
        float  horizonLift;

        #pragma body

        // Sprite alpha (SceneKit provides these built-ins).
        float2 uv  = _surface.diffuseTexcoord;
        float  a0  = u_diffuseTexture.sample(u_diffuseTextureSampler, uv).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Mild forward-scattering for sun punch.
        float3 rd   = float3(0.0f, 0.0f, 1.0f);
        float3 sunV = normalize(sunDirView);
        float  mu   = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g    = 0.55f;
        float  kph  = 1.55f * g - 0.55f * g * g;
        float  den  = 1.0f + kph * (1.0f - mu);
        float  phase= (1.0f - kph*kph) / (den*den + 1e-4f);

        // Rounder density from sprite alpha + thin vertical profile.
        float c       = clamp(coverage, 0.0f, 1.0f);
        float thresh  = clamp(0.56f - 0.36f * c, 0.20f, 0.62f);
        float soft    = 0.40f;                       // more softness => rounder edge
        float q       = clamp(stepMul, 0.7f, 1.5f);
        float kSigma  = 0.28f * q / 8.0f * max(0.7f, densityMul);   // denser core

        float  T = 1.0f;     // transmittance
        float  ss = 0.0f;    // single-scatter accumulator (scalar)

        // 8 fixed slices; only the alpha read above uses a sampler.
        { float h=0.0625f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.1875f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.3125f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.4375f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.5625f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.6875f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.8125f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }
        { float h=0.9375f; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
          float d=smoothstep(thresh-soft,thresh+soft,a0);
          float dens=max(0.0f,d*env)*1.18f;
          float a=exp(-kSigma*dens);
          ss += d * (1.0f - a) * (0.88f + 0.12f*phase);
          T *= a; }

        // Visibility & roundness: gamma on sprite alpha + volumetric term.
        float alphaOut = clamp(pow(a0, 0.52f) * (1.0f - pow(T, 0.55f)), 0.0f, 1.0f);

        // Colour: bright white with ambient lift; centre-weighted; premultiplied.
        float ambient = 0.65f;
        float gain    = 2.40f;
        float  centre = pow(a0, 0.60f);
        float3 Cpm    = float3(min(1.0f, ambient + gain * ss * centre));

        // Gentle horizon lift respecting alpha.
        Cpm += float3(horizonLift * (1.0f - uv.y) * 0.10f) * alphaOut;
        Cpm  = clamp(Cpm, float3(0.0f), float3(1.0f));

        _output.color = float4(Cpm * alphaOut, alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = false   // sky layer: draw-order only
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Sampling defaults
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults
        m.setValue(SCNVector3(0, 0, 1),          forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82),  forKey: "sunTint")
        m.setValue(0.42 as CGFloat,              forKey: "coverage")
        m.setValue(1.20 as CGFloat,              forKey: "densityMul")  // denser
        m.setValue(0.95 as CGFloat,              forKey: "stepMul")
        m.setValue(0.14 as CGFloat,              forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
