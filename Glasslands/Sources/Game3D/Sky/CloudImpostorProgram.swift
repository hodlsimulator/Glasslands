//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  SCNProgram for volumetric billboard impostors (pure vapour; no node-touching binders).
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial(halfSize: simd_float2) -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "cloud_impostor_vertex"
        prog.fragmentFunctionName = "cloud_impostor_fragment"
        prog.isOpaque = false

        // Reuse dome’s stable per-frame binder for uCloudsGL (no actor issues).
        prog.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: VolCloudBinder.bind)

        // Built-in semantic: pass the per-node model transform to symbol "uModel".
        // No options dictionary needed on iOS 26.
        prog.setSemantic(SCNModelTransform, forSymbol: "uModel", options: nil)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.program = prog

        // Per-material uniform used by the shader for edge falloff in local space.
        m.setValue(halfSize, forKey: "uHalfSize")
        return m
    }
}
