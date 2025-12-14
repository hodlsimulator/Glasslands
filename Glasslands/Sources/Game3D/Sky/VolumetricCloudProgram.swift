//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Metal SCNProgram wrapper for SkyVolumetricClouds.metal.
//
//  Key change:
//  - Clouds are rendered as ONE inside-out sphere using Metal (gl_vapour_*),
//    instead of hundreds of raymarched billboards.
//  - Uniforms are streamed from VolCloudUniformsStore into the shader buffer.
//

import SceneKit
import UIKit

enum VolumetricCloudProgram {

    // Shared program (one pipeline, one binder).
    @MainActor
    private static var program: SCNProgram = {
        let p = SCNProgram()
        p.vertexFunctionName = "gl_vapour_vertex"
        p.fragmentFunctionName = "gl_vapour_fragment"

        // SceneKit Metal buffer binding uses the *symbol name* in the Metal function signature.
        // Some versions of the shader have used "uCloudsGL" and some used a short "U".
        // Register both to make this robust without having to guess.
        let binder: SCNBufferBindingBlock = { (stream, _, _, _) in
            var snap = VolCloudUniformsStore.shared.snapshot()
            stream.writeBytes(&snap, count: MemoryLayout<GLCloudUniforms>.stride)
        }

        p.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: binder)
        p.handleBinding(ofBufferNamed: "U",        frequency: .perFrame, handler: binder)

        return p
    }()

    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()

        // This material is a sky layer: no depth, no lighting, alpha blended.
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front                   // inside-out sphere
        m.blendMode = .alpha
        m.transparencyMode = .aOne            // premultiplied output expected
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        // Program fully determines shading.
        m.program = program

        return m
    }
}
