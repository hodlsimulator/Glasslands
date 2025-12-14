//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Metal SCNProgram wrapper for SkyVolumetricClouds.metal.
//
//  Clouds are rendered as ONE inside-out sphere using Metal (gl_vapour_*),
//  instead of hundreds of raymarched billboards.
//  Uniforms are streamed from VolCloudUniformsStore into the shader buffer.
//

import SceneKit
import Metal

enum VolumetricCloudProgram {

    private final class ProgramDelegate: NSObject, SCNProgramDelegate {
        static let shared = ProgramDelegate()

        func program(_ program: SCNProgram, handleError error: Error) {
            // A failed program can present as a black sky layer.
            print("VolumetricCloudProgram error: \(error)")
        }
    }

    @MainActor
    private static var program: SCNProgram? = {
        let p = SCNProgram()
        p.vertexFunctionName = "gl_vapour_vertex"
        p.fragmentFunctionName = "gl_vapour_fragment"
        p.delegate = ProgramDelegate.shared

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("VolumetricCloudProgram: no Metal device available")
            return nil
        }

        if let lib = device.makeDefaultLibrary() {
            p.library = lib
        } else if let lib = try? device.makeDefaultLibrary(bundle: .main) {
            p.library = lib
        } else {
            print("VolumetricCloudProgram: failed to create default Metal library")
            return nil
        }

        // SceneKit Metal buffer binding uses the *symbol name* in the Metal function signature.
        // Some shader iterations used "U" and some used "uCloudsGL". Bind both.
        let binder: SCNBufferBindingBlock = { (stream, _, _, _) in
            var snap = VolCloudUniformsStore.shared.snapshot()
            stream.writeBytes(&snap, count: MemoryLayout<GLCloudUniforms>.stride)
        }

        p.handleBinding(ofBufferNamed: "U",        frequency: .perFrame, handler: binder)
        p.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: binder)

        return p
    }()

    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()

        // Sky layer: no depth, no lighting, alpha blended.
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        guard let p = program else {
            // Fail-safe: avoid an opaque/black layer if the program cannot compile.
            m.transparency = 0.0
            return m
        }

        m.program = p
        return m
    }
}
