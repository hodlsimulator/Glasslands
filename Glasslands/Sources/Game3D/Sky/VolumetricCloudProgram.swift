//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

import SceneKit
import simd
import UIKit

private struct CloudUniforms {
    var sunDirWorld: simd_float4
    var sunTint:     simd_float4
    var time:        Float
    var wind:        simd_float2
    var baseY:       Float
    var topY:        Float
    var coverage:    Float
    var densityMul:  Float
    var stepMul:     Float
    var horizonLift: Float
    var _pad:        Float = 0
}

enum VolumetricCloudProgram {

    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        let prog = SCNProgram()
        prog.vertexFunctionName   = "clouds_vertex"
        prog.fragmentFunctionName = "clouds_fragment"
        prog.delegate = ErrorLog.shared
        m.program = prog

        // Defaults; override via setValue(_:forKey:) if desired
        m.setValue(SCNVector3(0, 1, 0),          forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.0 as CGFloat,               forKey: "time")
        m.setValue(SCNVector3(6.0, 2.0, 0.0),    forKey: "wind") // xy used
        m.setValue(1350.0 as CGFloat,            forKey: "baseY")
        m.setValue(2500.0 as CGFloat,            forKey: "topY")
        m.setValue(0.55 as CGFloat,              forKey: "coverage")
        m.setValue(1.00 as CGFloat,              forKey: "densityMul")
        m.setValue(1.00 as CGFloat,              forKey: "stepMul")
        m.setValue(0.16 as CGFloat,              forKey: "horizonLift")

        // Only uniforms at buffer(2); no node access on render thread.
        prog.handleBinding(ofBufferNamed: "uniforms",
                           frequency: .perFrame,
                           handler: { (stream: SCNBufferStream, node: SCNNode?, shadable: SCNShadable, renderer: SCNRenderer) in
            guard let mat = (shadable as? SCNMaterial) else { return }

            func f(_ key: String, _ def: CGFloat) -> Float {
                if let cg = mat.value(forKey: key) as? CGFloat { return Float(cg) }
                return Float(def)
            }
            func v3(_ key: String, _ def: SCNVector3) -> simd_float3 {
                let v = (mat.value(forKey: key) as? SCNVector3) ?? def
                return simd_float3(Float(v.x), Float(v.y), Float(v.z))
            }

            let sunDir = simd_normalize(v3("sunDirWorld", SCNVector3(0,1,0)))
            let tint   = v3("sunTint", SCNVector3(1,1,1))
            let wind3  = v3("wind", SCNVector3(6,2,0))

            var U = CloudUniforms(
                sunDirWorld: simd_float4(sunDir, 0),
                sunTint:     simd_float4(tint, 0),
                time:        f("time", 0),
                wind:        simd_float2(wind3.x, wind3.y),
                baseY:       f("baseY", 1350),
                topY:        f("topY", 2500),
                coverage:    f("coverage", 0.55),
                densityMul:  f("densityMul", 1.0),
                stepMul:     f("stepMul", 1.0),
                horizonLift: f("horizonLift", 0.16)
            )

            stream.writeBytes(&U, count: MemoryLayout<CloudUniforms>.stride)
        })

        return m
    }

    private final class ErrorLog: NSObject, SCNProgramDelegate {
        static let shared = ErrorLog()
        func program(_ program: SCNProgram, handleError error: Error) {
            print("[VolumetricClouds] Metal compile error: \(error)")
        }
    }
}
