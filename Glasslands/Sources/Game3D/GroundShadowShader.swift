//
//  GroundShadowShader.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//

import SceneKit

enum GroundShadowShader {
    // Geometry stage: compute world-space position and pass it to the fragment stage.
    static let geometry: String = """
    #pragma varyings
    float3 v_worldPos;

    #pragma body
    float4 world = scn_node.modelTransform * _geometry.position;
    v_worldPos = world.xyz;
    """

    // Fragment stage: sample cloud shadow texture using world XZ and darken ground.
    static let fragment: String = """
    #pragma arguments
    texture2d<float> gl_shadowTex;
    float3 gl_shadowParams; // x=centerX, y=centerZ, z=halfSize

    #pragma varyings
    float3 v_worldPos;

    #pragma body
    float cx = gl_shadowParams.x;
    float cz = gl_shadowParams.y;
    float hs = max(1e-5, gl_shadowParams.z);

    float2 uv;
    uv.x = ((v_worldPos.x - cx) / (2.0 * hs)) + 0.5;
    uv.y = ((v_worldPos.z - cz) / (2.0 * hs)) + 0.5;

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float shade = gl_shadowTex.sample(s, uv).r;

    _output.color.rgb *= shade;
    """

    @MainActor
    static func applyIfNeeded(to material: SCNMaterial) {
        var mods = material.shaderModifiers ?? [:]
        mods[.geometry] = geometry
        mods[.fragment] = fragment
        material.shaderModifiers = mods
    }
}
