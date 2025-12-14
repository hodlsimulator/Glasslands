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
import UIKit
import Metal

enum VolumetricCloudProgram {

    private static let vertexFnName = "gl_vapour_vertex"
    private static let fragmentFnName = "gl_vapour_fragment"

    @MainActor
    private static var program: SCNProgram? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("VolumetricCloudProgram: Metal device unavailable")
            return nil
        }

        guard let lib = loadLibrary(device: device) else {
            print("VolumetricCloudProgram: default Metal library unavailable")
            return nil
        }

        // Critical: verify the functions exist in the library.
        // If they don't, SceneKit may still accept the SCNProgram and then fail at draw time,
        // which commonly manifests as an opaque black layer.
        guard lib.makeFunction(name: vertexFnName) != nil else {
            print("VolumetricCloudProgram: missing Metal function \(vertexFnName)")
            print("VolumetricCloudProgram: check SkyVolumetricClouds.metal is in the target’s Compile Sources")
            return nil
        }

        guard lib.makeFunction(name: fragmentFnName) != nil else {
            print("VolumetricCloudProgram: missing Metal function \(fragmentFnName)")
            print("VolumetricCloudProgram: check SkyVolumetricClouds.metal is in the target’s Compile Sources")
            return nil
        }

        let p = SCNProgram()
        p.library = lib
        p.vertexFunctionName = vertexFnName
        p.fragmentFunctionName = fragmentFnName
        p.delegate = ProgramDelegate.shared

        // Bind uniforms each frame. Supports both historical names ("U") and the newer ("uCloudsGL").
        let bindUniforms: SCNBufferBindingBlock = { bufferStream, _, _, _ in
            var u = VolCloudUniformsStore.shared.snapshot()
            withUnsafeBytes(of: &u) { raw in
                guard let base = raw.baseAddress else { return }
                bufferStream.writeBytes(base, count: raw.count)
            }
        }

        p.handleBinding(ofBufferNamed: "U", frequency: .perFrame, handler: bindUniforms)
        p.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: bindUniforms)

        return p
    }()

    @MainActor
    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        return try? device.makeDefaultLibrary(bundle: .main)
    }

    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        // Clouds are an overlay; alpha blending is expected.
        m.blendMode = .alpha
        m.transparencyMode = .aOne

        // Keep this from interfering with the depth buffer.
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        m.isLitPerPixel = false
        m.diffuse.contents = UIColor.white
        m.transparent.contents = UIColor.white

        guard let p = program else {
            // If the program isn't valid, make the layer disappear rather than drawing black.
            m.transparency = 0.0
            return m
        }

        m.program = p
        return m
    }

    private final class ProgramDelegate: NSObject, SCNProgramDelegate {
        static let shared = ProgramDelegate()

        func program(_ program: SCNProgram, handleError error: Error) {
            print("VolumetricCloudProgram error: \(error.localizedDescription)")
        }
    }
}
