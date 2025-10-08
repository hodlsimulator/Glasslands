//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Glasslands — binder-free (only per-node size)
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "cloud_impostor_vertex"
        prog.fragmentFunctionName = "cloud_impostor_fragment"
        prog.isOpaque = false

        // Model matrix → "uModel"
        prog.setSemantic(SCNModelTransform, forSymbol: "uModel", options: nil)

        // Per-node half-size → "uHalfSize" (cheap; no per-frame binders)
        prog.handleBinding(ofBufferNamed: "uHalfSize",
                           frequency: .perNode) { stream, node, _, _ in
            var hx: Float = 0.5
            var hy: Float = 0.5
            if let p = node.geometry as? SCNPlane {
                hx = Float(max(0.001, p.width  * 0.5))
                hy = Float(max(0.001, p.height * 0.5))
            } else if let g = node.geometry {
                let bb = g.boundingBox
                hx = Float(max(0.001, (bb.max.x - bb.min.x) * 0.5))
                hy = Float(max(0.001, (bb.max.y - bb.min.y) * 0.5))
            }
            var size = simd_float2(hx, hy)
            withUnsafeBytes(of: &size) { raw in
                stream.writeBytes(raw.baseAddress!, count: MemoryLayout<simd_float2>.size)
            }
        }

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        m.program = prog
        return m
    }
}
