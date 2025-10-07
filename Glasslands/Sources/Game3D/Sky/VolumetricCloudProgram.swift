//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  SCNProgram for SkyVolumetricClouds.metal. Binds a tightly-packed uClouds
//  constant buffer each frame from SCNMaterial custom keys.
//

import SceneKit
import simd
import UIKit

private struct CloudUniforms {
    var sunDirWorld : SIMD4<Float> // xyz dir
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float> // x=time, y=wind.x, z=wind.y, w=baseY
    var params1     : SIMD4<Float> // x=topY, y=coverage, z=densityMul, w=stepMul
    var params2     : SIMD4<Float> // x=mieG, y=powderK, z=horizonLift, w=detailMul
    var params3     : SIMD4<Float> // x=domainOffX, y=domainOffY, z=domainRotate, w=0
}

enum VolumetricCloudProgram {

    private static var currentU = CloudUniforms(
        sunDirWorld: SIMD4<Float>(0,1,0,0),
        sunTint    : SIMD4<Float>(1,1,1,0),
        params0    : SIMD4<Float>(0, 0.6, 0.2, 400.0),
        params1    : SIMD4<Float>(1400.0, 0.42, 1.20, 0.95),
        params2    : SIMD4<Float>(0.60, 2.20, 0.14, 1.10),
        params3    : SIMD4<Float>(0,0,0,0)
    )

    // Non-isolated binder called by SceneKit on its render queue
    private static func bindClouds(stream: SCNBufferStream, _: SCNNode, _: any SCNShadable, _: SCNRenderer) {
        var U = Self.currentU
        withUnsafeBytes(of: &U) { rawBuf in
            if let base = rawBuf.baseAddress {
                stream.writeBytes(base, count: rawBuf.count)
            }
        }
    }

    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "clouds_vertex"
        prog.fragmentFunctionName = "clouds_fragment"
        prog.handleBinding(ofBufferNamed: "uClouds", frequency: .perFrame, handler: bindClouds)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.program = prog

        // Default keys; engine updates these every frame
        m.setValue(NSNumber(value: 0.0), forKey: "time")
        m.setValue(SCNVector3(0.60, 0.20, 0), forKey: "wind")
        m.setValue(NSNumber(value: 400.0), forKey: "baseY")
        m.setValue(NSNumber(value: 1400.0), forKey: "topY")
        m.setValue(NSNumber(value: 0.42), forKey: "coverage")
        m.setValue(NSNumber(value: 1.20), forKey: "densityMul")
        m.setValue(NSNumber(value: 0.95), forKey: "stepMul")
        m.setValue(NSNumber(value: 0.60), forKey: "mieG")
        m.setValue(NSNumber(value: 2.20), forKey: "powderK")
        m.setValue(NSNumber(value: 0.14), forKey: "horizonLift")
        m.setValue(NSNumber(value: 1.10), forKey: "detailMul")
        m.setValue(SCNVector3(0,0,0), forKey: "domainOffset")
        m.setValue(NSNumber(value: 0.0), forKey: "domainRotate")
        m.setValue(SCNVector3(0,1,0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1,1,1), forKey: "sunTint")
        return m
    }

    // Called from render queue by your tick
    static func updateUniforms(from m: SCNMaterial) {
        func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        func v3(_ v: Any?) -> SIMD3<Float> {
            if let v = v as? SCNVector3 { return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
            return .zero
        }

        let time      = f(m.value(forKey: "time"))
        let wind      = v3(m.value(forKey: "wind"))
        let baseY     = f(m.value(forKey: "baseY"))
        let topY      = f(m.value(forKey: "topY"))
        let coverage  = f(m.value(forKey: "coverage"))
        let density   = f(m.value(forKey: "densityMul"))
        let stepMul   = f(m.value(forKey: "stepMul"))
        let mieG      = f(m.value(forKey: "mieG"))
        let powderK   = f(m.value(forKey: "powderK"))
        let horizon   = f(m.value(forKey: "horizonLift"))
        let detailMul = f(m.value(forKey: "detailMul"))
        let domOff    = v3(m.value(forKey: "domainOffset"))
        let domRot    = f(m.value(forKey: "domainRotate"))
        let sunW3     = v3(m.value(forKey: "sunDirWorld"))
        let sunTint3  = v3(m.value(forKey: "sunTint"))

        currentU.sunDirWorld = SIMD4<Float>(normalize(SIMD3<Float>(sunW3)), 0)
        currentU.sunTint     = SIMD4<Float>(sunTint3, 0)
        currentU.params0     = SIMD4<Float>(time, wind.x, wind.y, baseY)
        currentU.params1     = SIMD4<Float>(topY, coverage, max(0, density), max(0.25, stepMul))
        currentU.params2     = SIMD4<Float>(mieG, max(0, powderK), horizon, max(0, detailMul))
        currentU.params3     = SIMD4<Float>(domOff.x, domOff.y, domRot, 0)
    }
}
