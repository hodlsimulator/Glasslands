//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  SCNProgram for volumetric billboard impostors (true vapour).
//

import SceneKit
import simd
import UIKit

// Must match CloudImpostorVolumetric.metal's GLImpostorUniforms (16-byte aligned).
struct GLImpostorUniforms {
    var centerWorld: SIMD3<Float>
    var radius: Float
    var thickness: Float
    var soften: Float
    var pad: Float = 0
}

// Per-node model matrix for the vertex transform.
private struct NodeModel {
    var modelTransform: simd_float4x4
}

@objc final class CloudImpostorBinder: NSObject {

    // Per-frame: GLCloudUniforms (comes from VolCloudUniformsStore.shared).
    @objc static func bindClouds(_ stream: SCNBufferStream,
                                 node: SCNNode?,
                                 shadable: SCNShadable?,
                                 renderer: SCNRenderer)
    {
        let U = VolCloudUniformsStore.shared.snapshot()
        let byteCount = MemoryLayout<GLCloudUniforms>.stride
        withUnsafeBytes(of: U) { raw in
            guard let base = raw.baseAddress else { return }
            stream.writeBytes(base, count: byteCount)
        }
    }

    // Per-node: impostor sphere placement.
    @objc static func bindImpostor(_ stream: SCNBufferStream,
                                   node: SCNNode?,
                                   shadable: SCNShadable?,
                                   renderer: SCNRenderer)
    {
        let n = node?.presentation ?? node ?? SCNNode()
        let T = n.simdWorldTransform
        let center = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)

        var radius: Float = 2.0
        if let plane = n.geometry as? SCNPlane {
            radius = 0.5 * Float(max(plane.width, plane.height))
        } else if let g = n.geometry {
            let bs = g.boundingSphere
            radius = max(1.0, Float(bs.radius))
        }

        let U = GLImpostorUniforms(centerWorld: center,
                                   radius: radius,
                                   thickness: radius * 1.4,
                                   soften: 0.18,
                                   pad: 0)

        let byteCount = MemoryLayout<GLImpostorUniforms>.stride
        withUnsafeBytes(of: U) { raw in
            guard let base = raw.baseAddress else { return }
            stream.writeBytes(base, count: byteCount)
        }
    }

    // Per-node: model matrix for vertex transform (since SCNNodeBuffer isn’t a thing in SCNProgram).
    @objc static func bindModel(_ stream: SCNBufferStream,
                                node: SCNNode?,
                                shadable: SCNShadable?,
                                renderer: SCNRenderer)
    {
        let M = NodeModel(modelTransform: (node?.presentation ?? node ?? SCNNode()).simdWorldTransform)
        let byteCount = MemoryLayout<NodeModel>.stride
        withUnsafeBytes(of: M) { raw in
            guard let base = raw.baseAddress else { return }
            stream.writeBytes(base, count: byteCount)
        }
    }
}

enum CloudImpostorProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "cloud_impostor_vertex"
        prog.fragmentFunctionName = "cloud_impostor_fragment"
        prog.isOpaque = false

        // Match the Metal argument names.
        prog.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: CloudImpostorBinder.bindClouds)
        prog.handleBinding(ofBufferNamed: "uImpostor", frequency: .perNode,  handler: CloudImpostorBinder.bindImpostor)
        prog.handleBinding(ofBufferNamed: "uModel",    frequency: .perNode,  handler: CloudImpostorBinder.bindModel)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.program = prog
        return m
    }
}
