//
//  GroundShadowShader.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//

// Glasslands/Sources/Game3D/GroundShadowShader.swift

import SceneKit

enum GroundShadowShader {

    // Surface-stage modifier. Projects the sun’s cloud-shadow map onto world XZ.
    static let surface: String = """
    #pragma arguments
    texture2d gl_shadowTex;
    float3 gl_shadowParams; // x=centerX, y=centerZ, z=halfSize

    #pragma body
    float cx = gl_shadowParams.x;
    float cz = gl_shadowParams.y;
    float hs = max(1e-5, gl_shadowParams.z);

    float2 uv;
    uv.x = ((_surface.position.x - cx) / (2.0 * hs)) + 0.5;
    uv.y = ((_surface.position.z - cz) / (2.0 * hs)) + 0.5;

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float shade = clamp(gl_shadowTex.sample(s, uv).r, 0.0, 1.0);

    // Darken colour only; alpha unchanged to avoid colour wash.
    _surface.diffuse.rgb *= shade;
    """

    /// Attaches the surface shader and registers the material for param updates.
    @MainActor
    static func applyIfNeeded(to material: SCNMaterial) {
        if material.shaderModifiers == nil || material.shaderModifiers?[.surface] == nil {
            material.shaderModifiers = [.surface: surface]
        } else {
            material.shaderModifiers?[.surface] = surface
        }
        GroundShadowMaterials.shared.register(material)
    }
}
