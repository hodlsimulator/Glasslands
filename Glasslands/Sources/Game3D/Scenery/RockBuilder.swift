//
//  RockBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import simd
import GameplayKit

enum RockBuilder {
    static func makeRockNode(size: CGFloat,
                             palette: [UIColor],
                             rng: inout RandomAdaptor) -> (SCNNode, CGFloat) {
        let s = Float(size)
        // Base octahedron points
        var top = SIMD3<Float>(0,  s, 0)
        var bot = SIMD3<Float>(0, -s, 0)
        var ex  = SIMD3<Float>( s, 0, 0)
        var wx  = SIMD3<Float>(-s, 0, 0)
        var ez  = SIMD3<Float>(0, 0,  s)
        var wz  = SIMD3<Float>(0, 0, -s)

        @inline(__always)
        func jittered(_ v: SIMD3<Float>, amt: Float) -> SIMD3<Float> {
            var v = v
            v.x += Float.random(in: -amt...amt, using: &rng)
            v.y += Float.random(in: -amt...amt, using: &rng)
            v.z += Float.random(in: -amt...amt, using: &rng)
            return v
        }

        // Subtle shape randomness (no inout-ref arrays ⇒ no '&' error)
        top = jittered(top, amt: 0.12 * s)
        bot = jittered(bot, amt: 0.12 * s)
        ex  = jittered(ex,  amt: 0.18 * s)
        wx  = jittered(wx,  amt: 0.18 * s)
        ez  = jittered(ez,  amt: 0.18 * s)
        wz  = jittered(wz,  amt: 0.18 * s)

        var verts: [SIMD3<Float>] = []
        var norms: [SIMD3<Float>] = []
        var cols:  [UIColor] = []

        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ col: UIColor) {
            let ab = b - a, ac = c - a
            var n = simd_normalize(simd_cross(ab, ac))
            if !n.x.isFinite || !n.y.isFinite || !n.z.isFinite { n = SIMD3<Float>(0,1,0) }
            verts.append(contentsOf: [a, b, c])
            norms.append(contentsOf: [n, n, n])
            cols.append(contentsOf: [col, col, col])
        }

        let rockBase = palette.indices.contains(3) ? palette[3] : UIColor(white: 0.9, alpha: 1.0)
        func tint(_ c: UIColor) -> UIColor {
            c.adjustingHue(by: CGFloat.random(in: -0.02...0.02, using: &rng),
                           satBy: CGFloat.random(in: -0.05...0.05, using: &rng),
                           briBy: CGFloat.random(in: -0.06...0.03, using: &rng))
        }

        // Top fan
        tri(top, ex, ez, tint(rockBase))
        tri(top, ez, wx, tint(rockBase))
        tri(top, wx, wz, tint(rockBase))
        tri(top, wz, ex, tint(rockBase))
        // Bottom fan
        tri(bot, ez, ex, tint(rockBase))
        tri(bot, wx, ez, tint(rockBase))
        tri(bot, wz, wx, tint(rockBase))
        tri(bot, ex, wz, tint(rockBase))

        let vSrc = SCNGeometrySource(vertices: verts.map { SCNVector3($0.x, $0.y, $0.z) })
        let nSrc = SCNGeometrySource(normals: norms.map { SCNVector3($0.x, $0.y, $0.z) })
        let cSrc = geometrySourceForVertexColors(cols)

        var idx = Array(0..<verts.count).map { UInt16($0) }
        let elem = SCNGeometryElement(data: Data(bytes: &idx, count: idx.count * MemoryLayout<UInt16>.size),
                                      primitiveType: .triangles,
                                      primitiveCount: verts.count / 3,
                                      bytesPerIndex: MemoryLayout<UInt16>.size)

        let g = SCNGeometry(sources: [vSrc, nSrc, cSrc], elements: [elem])

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.96, alpha: 1.0)
        m.roughness.contents = 0.98
        m.metalness.contents = 0.0
        g.materials = [m]

        let node = SCNNode(geometry: g)
        node.categoryBitMask = 0x00000401
        node.castsShadow = false
        SceneryCommon.applyLOD(to: node, far: 120)

        return (node, size * 0.55)
    }
}
