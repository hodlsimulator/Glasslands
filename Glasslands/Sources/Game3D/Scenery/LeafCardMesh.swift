//
//  LeafCardMesh.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//

import SceneKit
import simd
import CoreGraphics

enum LeafCardMesh {

    /// One merged geometry containing many small quads (“leaf cards”).
    /// Cards face roughly outwards from the trunk axis with light noise.
    static func build(
        anchors: [SIMD3<Float>],
        totalCount: Int,
        sizeRange: SIMD2<Float>,
        rng: inout RandomAdaptor
    ) -> SCNGeometry {

        var positions: [SCNVector3] = []
        var normals:   [SCNVector3] = []
        var uvs:       [CGPoint]    = []
        var indices:   [Int32]      = []

        positions.reserveCapacity(totalCount * 4)
        normals.reserveCapacity(totalCount * 4)
        uvs.reserveCapacity(totalCount * 4)
        indices.reserveCapacity(totalCount * 6)

        let up = SIMD3<Float>(0,1,0)

        for _ in 0..<max(1, totalCount) {
            let anchor = anchors.randomElement(using: &rng) ?? SIMD3<Float>(0, 1, 0)

            // Scatter around the anchor
            var centre = anchor + SIMD3<Float>(
                Float.random(in: -0.6...0.6, using: &rng),
                Float.random(in: -0.4...0.4, using: &rng),
                Float.random(in: -0.6...0.6, using: &rng)
            )
            if !(centre.x.isFinite && centre.y.isFinite && centre.z.isFinite) { centre = anchor }

            var out = simd_normalize(SIMD3<Float>(centre.x, 0, centre.z))
            if !out.x.isFinite { out = SIMD3<Float>(1,0,0) }
            out = simd_normalize(out + SIMD3<Float>(
                Float.random(in: -0.25...0.25, using: &rng),
                Float.random(in: -0.15...0.15, using: &rng),
                Float.random(in: -0.25...0.25, using: &rng)
            ))

            let q = TreeMath.quatAligning(from: up, to: out)

            let h = Float.random(in: sizeRange.x...sizeRange.y, using: &rng)
            let w = h * Float.random(in: 0.45...0.75, using: &rng)

            let v0 = SIMD3<Float>(-w*0.5, 0, 0)
            let v1 = SIMD3<Float>( w*0.5, 0, 0)
            let v2 = SIMD3<Float>( w*0.5, h, 0)
            let v3 = SIMD3<Float>(-w*0.5, h, 0)

            let p0 = q.act(v0) + centre
            let p1 = q.act(v1) + centre
            let p2 = q.act(v2) + centre
            let p3 = q.act(v3) + centre

            let n  = simd_normalize(q.act(up))
            let base = Int32(positions.count)

            positions.append(SCNVector3(p0))
            positions.append(SCNVector3(p1))
            positions.append(SCNVector3(p2))
            positions.append(SCNVector3(p3))

            let N = SCNVector3(n.x, n.y, n.z)
            normals.append(N); normals.append(N); normals.append(N); normals.append(N)

            uvs.append(CGPoint(x: 0, y: 1))
            uvs.append(CGPoint(x: 1, y: 1))
            uvs.append(CGPoint(x: 1, y: 0))
            uvs.append(CGPoint(x: 0, y: 0))

            indices.append(contentsOf: [base, base+1, base+2, base, base+2, base+3])

            // Optional back card for a thicker look
            if Bool.random(using: &rng) {
                let q2 = TreeMath.quatAligning(from: up, to: -out)
                let p0b = q2.act(v0) + centre
                let p1b = q2.act(v1) + centre
                let p2b = q2.act(v2) + centre
                let p3b = q2.act(v3) + centre
                let nb  = simd_normalize(q2.act(up))
                let baseB = Int32(positions.count)

                positions.append(SCNVector3(p0b))
                positions.append(SCNVector3(p1b))
                positions.append(SCNVector3(p2b))
                positions.append(SCNVector3(p3b))

                let NB = SCNVector3(nb.x, nb.y, nb.z)
                normals.append(NB); normals.append(NB); normals.append(NB); normals.append(NB)

                uvs.append(CGPoint(x: 0, y: 1))
                uvs.append(CGPoint(x: 1, y: 1))
                uvs.append(CGPoint(x: 1, y: 0))
                uvs.append(CGPoint(x: 0, y: 0))

                indices.append(contentsOf: [baseB, baseB+1, baseB+2, baseB, baseB+2, baseB+3])
            }
        }

        let srcPos = SCNGeometrySource(vertices: positions)
        let srcNrm = SCNGeometrySource(normals: normals)
        let srcUV  = SCNGeometrySource(textureCoordinates: uvs)
        let elem   = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [srcPos, srcNrm, srcUV], elements: [elem])
    }
}
