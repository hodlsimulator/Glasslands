//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Single source of truth for the sprite material and its soft back-lighting.
//

import SceneKit

enum CloudBillboardMaterial {
    @MainActor
    static func makeTemplate() -> SCNMaterial {
        // Fragment-stage modifier without scn_frame: use a view-space sun passed from Swift.
        let fragment = """
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // unit vector in *view space* (set from Swift)
        float3 sunTint;
        float  sunBacklight;
        float  horizonFade;

        #pragma body
        if (_output.color.a < 0.004) { discard_fragment(); }

        // Keep sprite grain; avoid flattening into pure white
        float3 base = _output.color.rgb;
        float  luma = dot(base, float3(0.299, 0.587, 0.114));
        float  mid  = clamp(1.0 - abs(luma - 0.5) * 2.0, 0.0, 1.0);

        // View vector and sun already in *view space*
        float3 V    = normalize(_surface.view);
        float3 sunV = normalize(sunDirView);

        // Back-light rim
        float rim = clamp(dot(-V, sunV), 0.0, 1.0);
        rim = smoothstep(0.15, 0.90, rim);

        // Gentle lift near horizon to stop clouds falling into the gradient
        float w = (0.65 * rim + 0.20 * clamp(horizonFade, 0.0, 1.0)) * clamp(sunBacklight, 0.0, 2.0);

        // Screen-style add to preserve whites
        float3 add = sunTint * (w * mid);
        _output.color.rgb = base + add - base * add;
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.transparencyMode = .aOne           // premultiplied sprites
        m.blendMode = .alpha
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        m.shaderModifiers = [.fragment: fragment]

        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults; Swift updates per-frame
        m.setValue(SCNVector3(0, 0, 1), forKey: "sunDirView")        // placeholder
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.55 as CGFloat, forKey: "sunBacklight")
        m.setValue(0.18 as CGFloat, forKey: "horizonFade")
        return m
    }
}
