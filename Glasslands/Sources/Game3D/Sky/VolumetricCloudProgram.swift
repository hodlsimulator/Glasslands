//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  CNProgram wrapper for SkyVolumetricClouds.metal (gl_vapour_*).
//  Binder copies bytes from VolCloudUniformsStore into the buffer named "uCloudsGL".
//

// VolumetricCloudProgram.swift
// Glasslands
//
// Binder-free wrapper: delegate to the shader-modifier material.
// This removes render-queue closures entirely.

import SceneKit
import simd
import UIKit

@objc final class VolCloudBinder: NSObject {
    // SceneKit calls this on its render queue.
    @objc static func bind(_ stream: SCNBufferStream,
                           node: SCNNode?,
                           shadable: SCNShadable?,
                           renderer: SCNRenderer) {
        let U = VolCloudUniformsStore.shared.snapshot()
        withUnsafeBytes(of: U) { raw in
            stream.writeBytes(raw.baseAddress!, count: raw.count)
        }
    }
}

enum VolumetricCloudProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "gl_vapour_vertex"
        prog.fragmentFunctionName = "gl_vapour_fragment"

        // Bind the GLCloudUniforms struct each frame.
        prog.handleBinding(ofBufferNamed: "uCloudsGL",
                           frequency: .perFrame,
                           handler: VolCloudBinder.bind)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front           // inside-out sphere
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.program = prog

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
