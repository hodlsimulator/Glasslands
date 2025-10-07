//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  SCNProgram for SkyVolumetricClouds.metal. Binds a compact uClouds buffer
//  each frame from SCNMaterial values. Pure white, premultiplied output.
//

// VolumetricCloudProgram.swift — Glasslands
// SCNProgram wrapper for SkyVolumetricClouds.metal (unique names to avoid collisions).

import SceneKit
import simd
import UIKit

private struct GLCloudUniforms {
    var sunDirWorld : SIMD4<Float>
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float>   // x=time, y=wind.x, z=wind.y, w=baseY
    var params1     : SIMD4<Float>   // x=topY, y=coverage, z=densityMul, w=stepMul
    var params2     : SIMD4<Float>   // x=mieG, y=powderK, z=horizonLift, w=detailMul
    var params3     : SIMD4<Float>   // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    var params4     : SIMD4<Float>   // x=puffStrength
}

func GL_bindVolClouds(_ stream: SCNBufferStream,
                      _ node: SCNNode,
                      _ shadable: any SCNShadable,
                      _ renderer: SCNRenderer)
{
    guard let m = shadable as? SCNMaterial else { return }

    func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
    func v3(_ v: Any?) -> SIMD3<Float> {
        if let v = v as? SCNVector3 { return SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        return .zero
    }

    let time         = f(m.value(forKey: "time"))
    let wind         = v3(m.value(forKey: "wind"))
    let baseY        = f(m.value(forKey: "baseY"))
    let topY         = f(m.value(forKey: "topY"))
    let coverage     = f(m.value(forKey: "coverage"))
    let density      = f(m.value(forKey: "densityMul"))
    let stepMul      = f(m.value(forKey: "stepMul"))
    let mieG         = f(m.value(forKey: "mieG"))
    let powderK      = f(m.value(forKey: "powderK"))
    let horizon      = f(m.value(forKey: "horizonLift"))
    let detailMul    = f(m.value(forKey: "detailMul"))
    let domOff       = v3(m.value(forKey: "domainOffset"))
    let domRot       = f(m.value(forKey: "domainRotate"))
    let puffScale    = max(0.0001, f(m.value(forKey: "puffScale")))
    let puffStrength = max(0.0, f(m.value(forKey: "puffStrength")))
    let sunW3        = v3(m.value(forKey: "sunDirWorld"))
    let sunTint3     = v3(m.value(forKey: "sunTint"))

    var U = GLCloudUniforms(
        sunDirWorld: SIMD4(simd_normalize(SIMD3(sunW3)), 0),
        sunTint    : SIMD4(sunTint3, 0),
        params0    : SIMD4(time, wind.x, wind.y, baseY),
        params1    : SIMD4(topY, coverage, max(0, density), max(0.25, stepMul)),
        params2    : SIMD4(mieG, max(0, powderK), horizon, max(0, detailMul)),
        params3    : SIMD4(domOff.x, domOff.y, domRot, puffScale),
        params4    : SIMD4(puffStrength, 0, 0, 0)
    )

    withUnsafeBytes(of: &U) { rawBuf in
        if let base = rawBuf.baseAddress {
            stream.writeBytes(base, count: rawBuf.count)
        }
    }
}

enum VolumetricCloudProgram {
    static func makeMaterial() -> SCNMaterial {
        let prog = SCNProgram()
        prog.vertexFunctionName   = "gl_vapour_vertex"
        prog.fragmentFunctionName = "gl_vapour_fragment"
        // Must match the Metal parameter name `uCloudsGL`
        prog.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: GL_bindVolClouds)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.program = prog

        // Defaults (engine updates per-frame)
        m.setValue(0.0 as CGFloat, forKey: "time")
        m.setValue(SCNVector3(0.60, 0.20, 0), forKey: "wind")
        m.setValue(400.0 as CGFloat, forKey: "baseY")
        m.setValue(1400.0 as CGFloat, forKey: "topY")
        m.setValue(0.50 as CGFloat, forKey: "coverage")
        m.setValue(1.15 as CGFloat, forKey: "densityMul")
        m.setValue(0.85 as CGFloat, forKey: "stepMul")
        m.setValue(0.60 as CGFloat, forKey: "mieG")
        m.setValue(2.10 as CGFloat, forKey: "powderK")
        m.setValue(0.14 as CGFloat, forKey: "horizonLift")
        m.setValue(1.10 as CGFloat, forKey: "detailMul")
        m.setValue(SCNVector3(0,0,0), forKey: "domainOffset")
        m.setValue(0.0 as CGFloat, forKey: "domainRotate")
        m.setValue(0.0045 as CGFloat, forKey: "puffScale")
        m.setValue(0.65 as CGFloat, forKey: "puffStrength")
        m.setValue(SCNVector3(0,1,0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1,1,1), forKey: "sunTint")
        return m
    }
}
