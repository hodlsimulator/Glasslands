//
//  BranchTubeMesh.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//
//  Continuous tapered tube along a polyline (single SCNGeometry).
//

import SceneKit
import simd

enum BranchTubeMesh {

    /// Build a tapered tube along `points`, radius from rStart → rEnd.
    static func build(points: [SIMD3<Float>],
                      rStart: CGFloat,
                      rEnd: CGFloat,
                      radialSegments: Int = 8) -> SCNGeometry
    {
        let n = points.count
        if n < 2 {
            let cap = SCNCapsule(capRadius: max(0.01, rStart), height: max(0.05, rStart * 2))
            return cap
        }

        // Tangents
        var T = [SIMD3<Float>](repeating: SIMD3(0,1,0), count: n)
        for i in 0..<n {
            if i == 0      { T[i] = simd_normalize(points[1] - points[0]) }
            else if i == n-1 { T[i] = simd_normalize(points[i] - points[i-1]) }
            else           { T[i] = simd_normalize(points[i+1] - points[i-1]) }
        }

        // Parallel-transport frames
        var N = [SIMD3<Float>](repeating: SIMD3(1,0,0), count: n)
        var B = [SIMD3<Float>](repeating: SIMD3(0,0,1), count: n)
        let up = SIMD3<Float>(0,1,0)
        let xAxis = SIMD3<Float>(1,0,0)
        let firstRef = (abs(simd_dot(T[0], up)) > 0.9) ? xAxis : up
        N[0] = simd_normalize(simd_cross(T[0], firstRef))
        B[0] = simd_normalize(simd_cross(T[0], N[0]))
        N[0] = simd_normalize(simd_cross(B[0], T[0]))

        for i in 1..<n {
            let q = quatAlign(T[i-1], T[i])
            N[i] = simd_normalize(q.act(N[i-1]))
            B[i] = simd_normalize(simd_cross(T[i], N[i]))
            N[i] = simd_normalize(simd_cross(B[i], T[i]))
        }

        let rings = max(6, radialSegments)
        var pos: [SCNVector3] = []
        var nrm: [SCNVector3] = []
        var idx: [Int32] = []
        pos.reserveCapacity(n * rings)
        nrm.reserveCapacity(n * rings)
        idx.reserveCapacity((n - 1) * rings * 6)

        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let r = Float(rStart + (rEnd - rStart) * CGFloat(t))
            let C = points[i]; let Ni = N[i]; let Bi = B[i]
            for k in 0..<rings {
                let a = (Float(k) / Float(rings)) * (2 * .pi)
                let dir = cos(a) * Ni + sin(a) * Bi
                let P = C + dir * r
                pos.append(SCNVector3(P))
                nrm.append(SCNVector3(simd_normalize(dir)))
            }
        }

        for i in 0..<(n - 1) {
            let base0 = Int32(i * rings)
            let base1 = Int32((i + 1) * rings)
            for k in 0..<rings {
                let a = base0 + Int32(k)
                let b = base0 + Int32((k + 1) % rings)
                let c = base1 + Int32((k + 1) % rings)
                let d = base1 + Int32(k)
                idx.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        let srcPos = SCNGeometrySource(vertices: pos)
        let srcNrm = SCNGeometrySource(normals: nrm)
        let elem   = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        return SCNGeometry(sources: [srcPos, srcNrm], elements: [elem])
    }

    private static func quatAlign(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(u), t = simd_normalize(v)
        let c = simd_dot(f, t)
        if c > 0.9999 { return simd_quatf(angle: 0, axis: SIMD3(0,1,0)) }
        if c < -0.9999 {
            let axis0 = simd_cross(f, SIMD3<Float>(1,0,0))
            let axis = simd_length(axis0) < 1e-4 ? SIMD3<Float>(0,0,1) : simd_normalize(axis0)
            return simd_quatf(angle: .pi, axis: axis)
        }
        let axis = simd_normalize(simd_cross(f, t))
        let s = sqrt((1 + c) * 2)
        let invs = 1 / s
        return simd_quatf(ix: axis.x * invs, iy: axis.y * invs, iz: axis.z * invs, r: s * 0.5)
    }
}
