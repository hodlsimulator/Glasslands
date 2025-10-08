//
//  GroundShadowShader.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//

import SceneKit

enum GroundShadowShader {
    // Surface-stage: world-space position is available as _surface.position.
    static let surface: String = """
    #pragma arguments
    texture2d<float> gl_shadowTex;
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

    // Darken colour only; do NOT touch alpha or you get a blue wash over the world.
    _surface.diffuse.rgb *= shade;
    """

    @MainActor
    static func applyIfNeeded(to material: SCNMaterial) {
        material.shaderModifiers = [.surface: surface]
        GroundShadowMaterials.shared.register(material)
    }
}
