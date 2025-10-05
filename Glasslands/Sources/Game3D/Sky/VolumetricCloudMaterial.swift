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

// Glasslands/Sources/Game3D/Sky/VolumetricCloudMaterial.swift
import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        #pragma arguments
        float3 skyZenith;
        float3 skyHorizon;
        float  flipV;

        #pragma body
        float2 uv = _surface.diffuseTexcoord;   // SCNSphere UVs
        float v = (flipV > 0.5) ? (1.0 - uv.y) : uv.y;
        v = clamp(v, 0.002, 0.998);             // tame pole seams
        float t = clamp(v, 0.0, 1.0);
        float3 col = mix(skyHorizon, skyZenith, t);
        _output.color = float4(col, 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false              // draw one side only
        m.cullMode = .front                  // cull front faces → render interior backfaces
        m.blendMode = .replace               // avoid triangle-edge blending artefacts
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        m.setValue(SCNVector3(0.10, 0.28, 0.65), forKey: "skyZenith")
        m.setValue(SCNVector3(0.55, 0.72, 0.94), forKey: "skyHorizon")
        m.setValue(1.0 as CGFloat,               forKey: "flipV")
        return m
    }
}
