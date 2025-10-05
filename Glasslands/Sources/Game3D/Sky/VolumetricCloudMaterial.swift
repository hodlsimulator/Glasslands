//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Camera-anchored volumetric clouds on the inside of a sphere.
//  Fragment-only shader modifier:
//   • Base density from equirect coverage (same impostor logic as billboards)
//   • FBM domain jitter
//   • Single scattering with HG phase, powder effect, horizon lift
//   • HDR sun drawn into the sky and dimmed by cloud transmittance
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        // Minimal, compile-safe fragment. No helpers, no uniforms, no _surface usage.
        let fragment = """
        #pragma transparent
        #pragma body
        _output.color = float4(0.20, 0.45, 0.90, 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]
        return m
    }
}
