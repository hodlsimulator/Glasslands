//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Stable analytic billboard material (no SCNProgram). Used while we keep
//  the volumetric vapour dome for the real volumetric look.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {
    static let volumetricMarker = "/* ANALYTIC_BILLBOARD */"

    @MainActor
    static func makeVolumetricImpostor(defaultHalfSize: simd_float2 = .init(1, 1)) -> SCNMaterial {
        // Temporary: analytic, fast, safe. No SCNProgram usage here.
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne

        // Slight softness without textures.
        m.shaderModifiers = [
            .fragment:
            """
            #pragma transparent
            #pragma body
            // Preserve incoming premultiplied alpha; soften edge just a touch.
            float a = saturate(_output.color.a);
            _output.color.a = pow(a, 0.9);
            """
        ]

        m.setValue(volumetricMarker, forKey: "vapourTag")
        return m
    }

    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        return m
    }
}
