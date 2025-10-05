//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

import SceneKit
import simd
import UIKit
import os.lock

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

// Simple, lock-protected POD store; no MainActor usage here.
private final class CloudUniformStore {
    static let shared = CloudUniformStore()
    private var lock = os_unfair_lock_s()
    private var U = CloudUniforms(
        sunDirWorld: simd_float4(0, 1, 0, 0),
        sunTint:     simd_float4(1, 1, 1, 0),
        time:        0,
        wind:        simd_float2(6, 2),
        baseY:       1350,
        topY:        2500,
        coverage:    0.40,
        densityMul:  1.0,
        stepMul:     1.0,
        horizonLift: 0.16
    )

    func snapshot() -> CloudUniforms {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return U
    }

    func set(_ newValue: CloudUniforms) {
        os_unfair_lock_lock(&lock); U = newValue; os_unfair_lock_unlock(&lock)
    }

    // Per-frame update from the game loop (safe to call on main).
    func setTimeSun(time: Float, sun: simd_float3) {
        os_unfair_lock_lock(&lock)
        U.time = time
        U.sunDirWorld = simd_float4(simd_normalize(sun), 0)
        os_unfair_lock_unlock(&lock)
    }
}

enum VolumetricCloudProgram {

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
        // IMPORTANT: no delegate here (it’s called on the render queue).
        m.program = prog

        // Defaults (primed once; live values come from the POD each frame)
        m.setValue(SCNVector3(0, 1, 0),            forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.00, 0.94, 0.82),   forKey: "sunTint")
        m.setValue(0.0 as CGFloat,                 forKey: "time")
        m.setValue(SCNVector3(6.0, 2.0, 0.0),      forKey: "wind")
        m.setValue(1350.0 as CGFloat,              forKey: "baseY")
        m.setValue(2500.0 as CGFloat,              forKey: "topY")
        m.setValue(0.40  as CGFloat,               forKey: "coverage")
        m.setValue(1.00  as CGFloat,               forKey: "densityMul")
        m.setValue(1.00  as CGFloat,               forKey: "stepMul")
        m.setValue(0.16  as CGFloat,               forKey: "horizonLift")

        // Bind the POD buffer to the Metal arg name EXACTLY ("U") and with correct size.
        prog.handleBinding(ofBufferNamed: "U", frequency: .perFrame) { stream, _, _, _ in
            var U = CloudUniformStore.shared.snapshot()
            stream.writeBytes(&U, count: MemoryLayout<CloudUniforms>.stride)
        }

        // Prime the POD once from the material’s KVCs.
        updateUniforms(from: m)
        return m
    }

    // Called once on main when building the sky or changing sliders.
    static func updateUniforms(from mat: SCNMaterial) {
        func f(_ key: String, _ def: CGFloat) -> Float {
            if let cg = mat.value(forKey: key) as? CGFloat { return Float(cg) }
            return Float(def)
        }
        func v3(_ key: String, _ def: SCNVector3) -> simd_float3 {
            let v = (mat.value(forKey: key) as? SCNVector3) ?? def
            return simd_float3(Float(v.x), Float(v.y), Float(v.z))
        }

        let sunW   = simd_normalize(v3("sunDirWorld", SCNVector3(0, 1, 0)))
        let tint   = v3("sunTint",      SCNVector3(1, 1, 1))
        let wind3  = v3("wind",         SCNVector3(6, 2, 0))

        var U = CloudUniformStore.shared.snapshot()
        U.sunDirWorld = simd_float4(sunW, 0)
        U.sunTint     = simd_float4(tint, 0)
        U.time        = f("time", 0)
        U.wind        = simd_float2(wind3.x, wind3.y)
        U.baseY       = f("baseY", 1350)
        U.topY        = f("topY", 2500)
        U.coverage    = f("coverage", 0.40)
        U.densityMul  = f("densityMul", 1.0)
        U.stepMul     = f("stepMul", 1.0)
        U.horizonLift = f("horizonLift", 0.16)
        CloudUniformStore.shared.set(U)
    }

    // Per-frame call from your main-thread tick (already present in FirstPersonEngine).
    static func setPerFrame(time: Float, sunDirWorld: simd_float3) {
        CloudUniformStore.shared.setTimeSun(time: time, sun: sunDirWorld)
    }
}
