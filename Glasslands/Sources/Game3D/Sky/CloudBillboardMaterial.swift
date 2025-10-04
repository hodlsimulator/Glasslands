//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Single source of truth for the billboard sprite material.
//

import SceneKit

enum CloudBillboardMaterial {
    @MainActor
    static func makeTemplate() -> SCNMaterial {
        // Fragment modifier:
        //  • Discards near-zero alpha texels.
        //  • Subtle, view-dependent backlight from the sun.
        //  • Uses scn_frame.viewTransform (Metal) to turn world sun vector into view space.
        let fragment = """
        #pragma transparent
        #pragma arguments
        float3 sunDirWorld;
        float3 sunTint;
        float  sunBacklight;
        float  horizonFade;

        #pragma body
        if (_output.color.a < 0.004) { discard_fragment(); }

        // World → view space (Metal path).
        float3 sunV = normalize((scn_frame.viewTransform * float4(sunDirWorld, 0.0)).xyz);
        float3 V = normalize(_surface.view);

        // Strong when the sun is behind the sprite relative to the eye.
        float rim = clamp(dot(-V, sunV), 0.0, 1.0);
        rim = smoothstep(0.20, 0.95, rim);

        float hf = clamp(horizonFade, 0.0, 1.0);

        // Gentle brighten with backlight.
        float boost = rim * sunBacklight;
        _output.color.rgb *= (1.0 + boost);

        // Warm tint near the rim.
        float3 tint = mix(float3(1.0), sunTint, rim);
        _output.color.rgb = mix(_output.color.rgb, _output.color.rgb * tint, 0.6 * rim + 0.2 * hf);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = true   // safer for billboards

        m.shaderModifiers = [.fragment: fragment]

        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults; FirstPersonEngine overwrites after building the layer.
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.45 as CGFloat,             forKey: "sunBacklight")
        m.setValue(0.20 as CGFloat,             forKey: "horizonFade")

        return m
    }
}
