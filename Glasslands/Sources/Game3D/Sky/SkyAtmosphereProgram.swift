//
//  SkyAtmosphereProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  SCNProgram bridge for SkyAtmosphere.metal.
//  Binder is a top-level function that reads directly from the material.
//

import SceneKit
import simd
import UIKit

private struct SkyUniforms {
    var sunDirWorld : SIMD4<Float>
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float> // x=turbidity, y=mieG, z=exposure, w=horizonLift
}

// Top-level, non-isolated binder for SceneKit’s render queue.
func GL_bindSky(_ stream: SCNBufferStream, _ node: SCNNode, _ shadable: any SCNShadable, _ renderer: SCNRenderer) { 
    guard let m = shadable as? SCNMaterial else { return }

    func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
    func v3(_ v: Any?) -> SIMD3<Float> {
        if let s = v as? SCNVector3 { return SIMD3(Float(s.x), Float(s.y), Float(s.z)) }
        return .zero
    }

    let sun = v3(m.value(forKey: "sunDirWorld"))
    let tint = v3(m.value(forKey: "sunTint"))
    let turbidity  = f(m.value(forKey: "turbidity"))
    let mieG       = f(m.value(forKey: "mieG"))
    let exposure   = max(0, f(m.value(forKey: "exposure")))
    let horizon    = max(0, f(m.value(forKey: "horizonLift")))

    var U = SkyUniforms(
        sunDirWorld: SIMD4<Float>(normalize(SIMD3<Float>(sun)), 0),
        sunTint    : SIMD4<Float>(tint, 0),
        params0    : SIMD4<Float>(turbidity, mieG, exposure, horizon)
    )

    withUnsafeBytes(of: &U) { raw in
        if let base = raw.baseAddress {
            stream.writeBytes(base, count: raw.count)
        }
    }
}

enum SkyAtmosphereProgram {

    static func makeMaterial() -> SCNMaterial {
        let p = SCNProgram()
        p.vertexFunctionName   = "sky_vertex"
        p.fragmentFunctionName = "sky_fragment"
        p.handleBinding(ofBufferNamed: "U", frequency: .perFrame, handler: GL_bindSky)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.program = p

        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1, 1, 1), forKey: "sunTint")
        m.setValue(2.5 as CGFloat, forKey: "turbidity")
        m.setValue(0.60 as CGFloat, forKey: "mieG")
        m.setValue(1.25 as CGFloat, forKey: "exposure")
        m.setValue(0.12 as CGFloat, forKey: "horizonLift")
        return m
    }

    // Kept for compatibility; binder reads from the material directly.
    static func updateUniforms(from _: SCNMaterial) {}
}
