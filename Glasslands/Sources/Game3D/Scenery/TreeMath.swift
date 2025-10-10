//
//  TreeMath.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//

import simd

enum TreeMath {
    static func quatAligning(from u: SIMD3<Float>, to v: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(u)
        let t = simd_normalize(v)
        let c = simd_dot(f, t)
        if c > 0.9999 { return simd_quatf(angle: 0, axis: SIMD3(0,1,0)) }
        if c < -0.9999 {
            let axis0 = simd_cross(f, SIMD3(1,0,0))
            let axis = simd_length(axis0) < 1e-4 ? SIMD3(0,0,1) : simd_normalize(axis0)
            return simd_quatf(angle: .pi, axis: axis)
        }
        let axis = simd_normalize(simd_cross(f, t))
        let s = sqrt((1 + c) * 2)
        let invs = 1 / s
        return simd_quatf(ix: axis.x * invs, iy: axis.y * invs, iz: axis.z * invs, r: s * 0.5)
    }

    static func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
}
