//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  SCNProgram wrapper for SkyVolumetricClouds.metal (unique symbols).
//  Binder copies bytes from VolCloudUniformsStore; it never touches SCNMaterial.
//

import SceneKit
import simd
import UIKit

@objc
final class VolCloudBinder: NSObject {
    @objc static func bind(_ stream: SCNBufferStream,
                           node: SCNNode?,
                           shadable: SCNShadable?,
                           renderer: SCNRenderer)
    {
        let U = VolCloudUniformsStore.shared.snapshot()
        let size = MemoryLayout<GLCloudUniforms>.size
        let ptr = UnsafeMutablePointer<GLCloudUniforms>.allocate(capacity: 1)
        ptr.initialize(to: U)
        stream.writeBytes(UnsafeRawPointer(ptr), count: size)
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }
}

enum VolumetricCloudProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "gl_vapour_vertex"
        prog.fragmentFunctionName = "gl_vapour_fragment"
        // Name must match the Metal parameter `uCloudsGL`
        prog.handleBinding(ofBufferNamed: "uCloudsGL",
                           frequency: .perFrame,
                           handler: VolCloudBinder.bind)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.program = prog
        return m
    }
}
