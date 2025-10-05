//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  SCNProgram + Metal uniforms for the volumetric cloud dome.
//

import SceneKit
import simd
import UIKit
import os.lock

// Must match the Metal layout exactly (packed into float4s).
private struct CloudUniforms {
    var sunDirWorld : simd_float4
    var sunTint     : simd_float4
    var params0     : simd_float4   // x=time, y=wind.x, z=wind.y, w=baseY
    var params1     : simd_float4   // x=topY, y=coverage, z=densityMul, w=stepMul
    var params2     : simd_float4   // x=mieG, y=powderK, z=horizonLift, w=detailMul
}

// Simple lock‑protected POD store.
private final class CloudUniformStore {
    static let shared = CloudUniformStore()

    private var lock = os_unfair_lock_s()
    private var U = CloudUniforms(
        sunDirWorld: simd_float4(0, 1, 0, 0),
        sunTint:     simd_float4(1.00, 0.94, 0.82, 0),
        params0:     simd_float4(0, 6, 2, 1350),      // time, windX, windY, baseY
        params1:     simd_float4(2500, 0.42, 1.30, 0.95), // topY, coverage, densityMul, stepMul
        params2:     simd_float4(0.65, 1.80, 0.18, 1.00)  // g, powderK, horizonLift, detailMul
    )

    func snapshot() -> CloudUniforms {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return U
    }

    func set(_ newValue: CloudUniforms) {
        os_unfair_lock_lock(&lock); U = newValue; os_unfair_lock_unlock(&lock)
    }

    // Per‑frame update (main thread safe).
    func setTimeSun(time: Float, sun: simd_float3) {
        os_unfair_lock_lock(&lock)
        U.params0.x = time
        U.sunDirWorld = simd_float4(simd_normalize(sun), 0)
        os_unfair_lock_unlock(&lock)
    }
}

enum VolumetricCloudProgram {

    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.blendMode = .alpha          // composite with the skydome behind
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        let prog = SCNProgram()
        prog.vertexFunctionName   = "clouds_vertex"
        prog.fragmentFunctionName = "clouds_fragment"
        m.program = prog

        // Bind the POD buffer named "U"
        prog.handleBinding(ofBufferNamed: "U", frequency: .perFrame) { stream, _, _, _ in
            var U = CloudUniformStore.shared.snapshot()
            stream.writeBytes(&U, count: MemoryLayout<CloudUniforms>.stride)
        }

        // Defaults exposed via KVC (so gameplay code can tweak live):
        m.setValue(SCNVector3(0, 1, 0),                         forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.00, 0.94, 0.82),                forKey: "sunTint")
        m.setValue(0.0 as CGFloat,                              forKey: "time")
        m.setValue(SCNVector3(6.0, 2.0, 0.0),                   forKey: "wind")
        m.setValue(1350.0 as CGFloat,                           forKey: "baseY")
        m.setValue(2500.0 as CGFloat,                           forKey: "topY")
        m.setValue(0.42 as CGFloat,                             forKey: "coverage")
        m.setValue(1.30 as CGFloat,                             forKey: "densityMul")
        m.setValue(0.95 as CGFloat,                             forKey: "stepMul")
        m.setValue(0.18 as CGFloat,                             forKey: "horizonLift")
        m.setValue(0.65 as CGFloat,                             forKey: "mieG")
        m.setValue(1.80 as CGFloat,                             forKey: "powderK")
        m.setValue(1.00 as CGFloat,                             forKey: "detailMul")

        // Prime the store from these defaults.
        updateUniforms(from: m)
        return m
    }

    // Update the POD from an SCNMaterial’s KVCs (main thread).
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
        let tint   = v3("sunTint", SCNVector3(1, 1, 1))
        let wind3  = v3("wind",    SCNVector3(6, 2, 0))

        var U = CloudUniformStore.shared.snapshot()
        U.sunDirWorld = simd_float4(sunW, 0)
        U.sunTint     = simd_float4(tint, 0)

        U.params0 = simd_float4(
            f("time", 0),
            wind3.x, wind3.y,
            f("baseY", 1350)
        )

        U.params1 = simd_float4(
            f("topY", 2500),
            f("coverage", 0.42),
            f("densityMul", 1.30),
            f("stepMul", 0.95)
        )

        U.params2 = simd_float4(
            f("mieG", 0.65),
            f("powderK", 1.80),
            f("horizonLift", 0.18),
            f("detailMul", 1.00)
        )

        CloudUniformStore.shared.set(U)
    }

    // Per‑frame call from the renderer.
    static func setPerFrame(time: Float, sunDirWorld: simd_float3) {
        CloudUniformStore.shared.setTimeSun(time: time, sun: sunDirWorld)
    }
}
