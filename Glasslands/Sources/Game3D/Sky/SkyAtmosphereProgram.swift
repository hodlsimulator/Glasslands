//
//  SkyAtmosphereProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  SCNProgram bridge for SkyAtmosphere.metal
//

import SceneKit
import simd
import UIKit

private struct SkyUniforms {
    var sunDirWorld : SIMD4<Float>
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float> // x=turbidity, y=mieG, z=exposure, w=horizonLift
}

enum SkyAtmosphereProgram {

    private static var U = SkyUniforms(
        sunDirWorld: SIMD4<Float>(0, 1, 0, 0),
        sunTint    : SIMD4<Float>(1, 1, 1, 0),
        params0    : SIMD4<Float>(2.5, 0.6, 1.25, 0.12)
    )

    // Non-isolated binder used by SceneKit render queue
    private static func bindSky(stream: SCNBufferStream, _: SCNNode, _: any SCNShadable, _: SCNRenderer) {
        var u = U
        withUnsafeBytes(of: &u) { raw in
            if let base = raw.baseAddress {
                stream.writeBytes(base, count: raw.count)
            }
        }
    }

    static func makeMaterial() -> SCNMaterial {
        let p = SCNProgram()
        p.vertexFunctionName   = "sky_vertex"
        p.fragmentFunctionName = "sky_fragment"
        p.handleBinding(ofBufferNamed: "U", frequency: .perFrame, handler: bindSky)

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

    // Called from render queue by your tick
    static func updateUniforms(from m: SCNMaterial) {
        func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        func v3(_ v: Any?) -> SIMD3<Float> {
            if let s = v as? SCNVector3 { return SIMD3(Float(s.x), Float(s.y), Float(s.z)) }
            return .zero
        }
        let sun = v3(m.value(forKey: "sunDirWorld"))
        let tint = v3(m.value(forKey: "sunTint"))
        U.sunDirWorld = SIMD4<Float>(normalize(SIMD3<Float>(sun)), 0)
        U.sunTint     = SIMD4<Float>(tint, 0)
        U.params0     = SIMD4<Float>(
            f(m.value(forKey: "turbidity")),
            f(m.value(forKey: "mieG")),
            max(0, f(m.value(forKey: "exposure"))),
            max(0, f(m.value(forKey: "horizonLift")))
        )
    }
}
