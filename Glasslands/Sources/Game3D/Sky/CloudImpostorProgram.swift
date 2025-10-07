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

// Must match CloudImpostorVolumetric.metal's GLImpostorUniforms (16‑byte aligned).
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

    /// Pulls presentation transform + a radius **without** tripping Swift 6 actor checks.
    /// Everything inside `assumeIsolated` is treated as MainActor for isolation purposes.
    private static func unsafeReadNodeState(_ node: SCNNode?) -> (centre: SIMD3<Float>, radius: Float, model: simd_float4x4) {
        return MainActor.assumeIsolated {
            let n = node?.presentation ?? node ?? SCNNode()
            let T = n.simdWorldTransform

            // World-space centre from matrix.
            let centre = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)

            // Heuristic radius from geometry bounds.
            var radius: Float = 2.0
            if let plane = n.geometry as? SCNPlane {
                radius = 0.5 * Float(max(plane.width, plane.height))
            } else if let g = n.geometry {
                let bs = g.boundingSphere
                radius = max(1.0, Float(bs.radius))
            }

            return (centre, radius, T)
        }
    }

    // Per-node: impostor sphere placement (centre / radius / soft edge).
    @objc static func bindImpostor(_ stream: SCNBufferStream,
                                   node: SCNNode?,
                                   shadable: SCNShadable?,
                                   renderer: SCNRenderer)
    {
        let (centre, radius, _) = unsafeReadNodeState(node)

        // Soft edge tuned for volumetric look; thickness caps ray span to reduce work.
        let U = GLImpostorUniforms(centerWorld: centre,
                                   radius: radius,
                                   thickness: min(radius * 1.4, radius * 2.0),
                                   soften: 0.18,
                                   pad: 0)

        // Copy via a temporary pointer (avoids overlapping access diagnostics in Swift 6).
        let ptr = UnsafeMutablePointer<GLImpostorUniforms>.allocate(capacity: 1)
        ptr.initialize(to: U)
        stream.writeBytes(UnsafeRawPointer(ptr), count: MemoryLayout<GLImpostorUniforms>.stride)
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }

    // Per-node: model matrix for vertex transform in the program’s vertex function.
    @objc static func bindModel(_ stream: SCNBufferStream,
                                node: SCNNode?,
                                shadable: SCNShadable?,
                                renderer: SCNRenderer)
    {
        let (_, _, model) = unsafeReadNodeState(node)
        let M = NodeModel(modelTransform: model)

        let ptr = UnsafeMutablePointer<NodeModel>.allocate(capacity: 1)
        ptr.initialize(to: M)
        stream.writeBytes(UnsafeRawPointer(ptr), count: MemoryLayout<NodeModel>.stride)
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }
}

enum CloudImpostorProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "cloud_impostor_vertex"
        prog.fragmentFunctionName = "cloud_impostor_fragment"
        prog.isOpaque = false

        // Reuse the already-stable per-frame binder for the vapour uniforms.
        // (Lives in VolumetricCloudProgram.swift)
        prog.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: VolCloudBinder.bind)

        // Our per-node binders. These no longer touch SCNNode APIs outside of an `assumeIsolated` block.
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

