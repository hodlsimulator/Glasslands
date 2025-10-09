//
//  GroundShadowShader.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//

import SceneKit

enum GroundShadowShader {

    // Surface-stage modifier: blends previous and current cloud-shadow maps to smooth updates.
    static let surface: String = """
    #pragma arguments
    texture2d<float> gl_shadowTex0;
    sampler          gl_shadowTex0Sampler;
    texture2d<float> gl_shadowTex1;
    sampler          gl_shadowTex1Sampler;
    float3           gl_shadowParams0;   // x=centerX, y=centerZ, z=halfSize
    float3           gl_shadowParams1;   // x=centerX, y=centerZ, z=halfSize
    float            gl_shadowMix;       // 0..1 (blend from 0:Tex0 → 1:Tex1)

    #pragma body
    float2 uv0, uv1;

    float cx0 = gl_shadowParams0.x;
    float cz0 = gl_shadowParams0.y;
    float hs0 = max(1e-5, gl_shadowParams0.z);

    uv0.x = ((_surface.position.x - cx0) / (2.0 * hs0)) + 0.5;
    uv0.y = ((_surface.position.z - cz0) / (2.0 * hs0)) + 0.5;

    float cx1 = gl_shadowParams1.x;
    float cz1 = gl_shadowParams1.y;
    float hs1 = max(1e-5, gl_shadowParams1.z);

    uv1.x = ((_surface.position.x - cx1) / (2.0 * hs1)) + 0.5;
    uv1.y = ((_surface.position.z - cz1) / (2.0 * hs1)) + 0.5;

    float s0 = clamp(gl_shadowTex0.sample(gl_shadowTex0Sampler, uv0).r, 0.0, 1.0);
    float s1 = clamp(gl_shadowTex1.sample(gl_shadowTex1Sampler, uv1).r, 0.0, 1.0);

    float t = clamp(gl_shadowMix, 0.0, 1.0);
    float shade = mix(s0, s1, t);

    _surface.diffuse.rgb *= shade;
    """

    @MainActor
    static func applyIfNeeded(to material: SCNMaterial) {
        if material.shaderModifiers == nil || material.shaderModifiers?[.surface] == nil {
            material.shaderModifiers = [.surface: surface]
        } else {
            material.shaderModifiers?[.surface] = surface
        }

        // Safe defaults so rendering never faults before the first update.
        if material.value(forKey: "gl_shadowParams0") == nil {
            material.setValue(NSValue(scnVector3: SCNVector3(0, 0, 1)), forKey: "gl_shadowParams0")
        }
        if material.value(forKey: "gl_shadowParams1") == nil {
            material.setValue(NSValue(scnVector3: SCNVector3(0, 0, 1)), forKey: "gl_shadowParams1")
        }
        if material.value(forKey: "gl_shadowMix") == nil {
            material.setValue(NSNumber(value: 1.0), forKey: "gl_shadowMix")
        }

        let white = UIColor.white
        if material.value(forKey: "gl_shadowTex0") == nil {
            let p = SCNMaterialProperty(contents: white)
            p.wrapS = .clamp; p.wrapT = .clamp
            p.minificationFilter = .linear; p.magnificationFilter = .linear
            material.setValue(p, forKey: "gl_shadowTex0")
        }
        if material.value(forKey: "gl_shadowTex1") == nil {
            let p = SCNMaterialProperty(contents: white)
            p.wrapS = .clamp; p.wrapT = .clamp
            p.minificationFilter = .linear; p.magnificationFilter = .linear
            material.setValue(p, forKey: "gl_shadowTex1")
        }

        GroundShadowMaterials.shared.register(material)
    }
}
