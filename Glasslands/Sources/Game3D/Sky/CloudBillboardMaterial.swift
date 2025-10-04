//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Single source of truth for sprite material settings.
//

import SceneKit

enum CloudBillboardMaterial {

    @MainActor static func makeTemplate() -> SCNMaterial {
        // Trim ultra‑low alphas early to avoid far‑mip fogging.
        let fragment = """
        #pragma transparent
        #pragma body
        if (_output.color.a < 0.004) { discard_fragment(); }
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.transparencyMode = .aOne        // premultiplied alpha
        m.blendMode = .alpha
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        m.shaderModifiers = [.fragment: fragment]

        // Clamp sampling; sprites carry a hard transparent frame to be clamp/mip safe.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0
        return m
    }
}
