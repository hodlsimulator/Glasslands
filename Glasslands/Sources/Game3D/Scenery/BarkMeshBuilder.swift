//
//  BarkMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//

import SceneKit
import simd
import CoreGraphics

enum BarkMeshBuilder {

    struct Output {
        let node: SCNNode
        let leafAnchors: [SIMD3<Float>]
    }

    /// Build trunk + jagged, upward-angled branches. Returns a flattened bark mesh and anchor points for leaves.
    static func build(
        species: TreeBuilder3D.Species,
        totalHeight: CGFloat,
        trunkHeight: CGFloat,
        trunkRadius: CGFloat,
        primaryCount: Int,
        secondaryPerPrimary: ClosedRange<Int>,
        branchTilt: ClosedRange<CGFloat>,      // radians
        crownRatio: ClosedRange<CGFloat>,      // 0…1 along branch
        material: SCNMaterial,
        rng: inout RandomAdaptor
    ) -> Output {

        let group = SCNNode()

        // Trunk with a subtle taper cap
        let trunk = makeTrunk(height: trunkHeight, radius: trunkRadius, material: material)
        group.addChildNode(trunk)

        var anchors: [SIMD3<Float>] = []
        let crownH = max(1.0, totalHeight - trunkHeight)

        let startY = trunkHeight * CGFloat.random(in: 0.62...0.78, using: &rng)
        let ringR  = max(trunkRadius * 1.2, totalHeight * 0.05)
        let ringN  = max(3, primaryCount)

        for i in 0..<ringN {
            let baseAngle = (2.0 * .pi / CGFloat(ringN)) * CGFloat(i) + CGFloat.random(in: -0.18...0.18, using: &rng)
            let outwardXZ = SIMD3<Float>(Float(cos(baseAngle)), 0, Float(sin(baseAngle)))

            // Start point on a ring
            let base = SIMD3<Float>(Float(ringR * cos(baseAngle)), Float(startY), Float(ringR * sin(baseAngle)))

            // Length and initial direction
            let len  = Float(crownH) * Float.random(in: 0.60...0.85, using: &rng)
            let upTilt = Float(CGFloat.random(in: branchTilt, using: &rng))
            var dir0 = simd_normalize(outwardXZ + SIMD3<Float>(0, tan(upTilt), 0))

            // Primary branch polyline: upward-biased jagged path
            let primSegs = Int.random(in: 4...6, using: &rng)
            let prim = makeJaggedPolyline(from: base, dir: dir0, length: len,
                                          upBias: 0.20...0.40, yawJitter: 0.25, pitchJitter: 0.18,
                                          segments: primSegs, rng: &rng)

            // Create tapered cone segments along the polyline
            let rBase = trunkRadius * CGFloat.random(in: 0.28...0.38, using: &rng)
            var tAccum: Float = 0
            for s in 0..<(prim.count - 1) {
                let a = prim[s], b = prim[s + 1]
                let segLen = simd_length(b - a); if segLen < 0.02 { continue }
                tAccum += segLen / len
                let t    = max(0, min(1, tAccum))
                let r0   = rBase * CGFloat(1.0 - 0.65 * t)
                let r1   = max(0.02, r0 * 0.6)
                addConeSegment(from: a, to: b, r0: r0, r1: r1, mat: material, parent: group)
            }

            // Secondaries from random points along primary
            let secCount = Int.random(in: secondaryPerPrimary, using: &rng)
            for _ in 0..<secCount {
                let idx = Int.random(in: 1..<(prim.count - 1), using: &rng)
                let anchor = prim[idx]
                let tangent = simd_normalize(prim[idx] - prim[max(0, idx - 1)])
                let side = simd_normalize(simd_cross(tangent, SIMD3<Float>(0,1,0)))
                let out  = simd_normalize(tangent + side * Float.random(in: -0.7...0.7, using: &rng) + SIMD3<Float>(0, Float.random(in: 0.1...0.4, using: &rng), 0))

                let len2 = len * Float.random(in: 0.25...0.45, using: &rng)
                let segs = Int.random(in: 3...4, using: &rng)
                let sec = makeJaggedPolyline(from: anchor, dir: out, length: len2,
                                             upBias: 0.18...0.32, yawJitter: 0.30, pitchJitter: 0.20,
                                             segments: segs, rng: &rng)

                let r2Base = rBase * CGFloat.random(in: 0.26...0.36, using: &rng)
                var t2: Float = 0
                for s in 0..<(sec.count - 1) {
                    let a = sec[s], b = sec[s + 1]
                    let segLen = simd_length(b - a); if segLen < 0.02 { continue }
                    t2 += segLen / len2
                    let t = max(0, min(1, t2))
                    let r0 = r2Base * CGFloat(1.0 - 0.65 * t)
                    let r1 = max(0.015, r0 * 0.55)
                    addConeSegment(from: a, to: b, r0: r0, r1: r1, mat: material, parent: group)
                }

                // Leaf anchors along the last third
                for s in Int(Float(sec.count) * 0.66)..<sec.count {
                    let c = sec[s]
                    let ct = CGFloat.random(in: crownRatio, using: &rng)
                    let next = sec[min(sec.count - 1, s + 1)]
                    anchors.append(TreeMath.lerp(c, next, Float(ct)))
                }
            }

            // Leaf anchors near primary tip
            for s in Int(Float(prim.count) * 0.66)..<prim.count {
                let c = prim[s]
                let ct = CGFloat.random(in: crownRatio, using: &rng)
                let next = prim[min(prim.count - 1, s + 1)]
                anchors.append(TreeMath.lerp(c, next, Float(ct)))
            }
        }

        // Flatten to one bark mesh (cheap draw)
        let barkMesh = group.flattenedClone()
        barkMesh.name = "TreeBark"
        barkMesh.castsShadow = true
        if let g = barkMesh.geometry {
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 220)]
        }

        return Output(node: barkMesh, leafAnchors: anchors)
    }

    // MARK: - Pieces

    private static func makeTrunk(height: CGFloat, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let cyl = SCNCylinder(radius: radius, height: height)
        cyl.radialSegmentCount = 12
        cyl.heightSegmentCount = 1
        cyl.materials = [material]

        let n = SCNNode(geometry: cyl)
        n.position = SCNVector3(0, height * 0.5, 0)

        let cap = SCNCone(topRadius: radius * 0.72, bottomRadius: radius, height: max(0.4, height * 0.08))
        cap.radialSegmentCount = 10
        cap.materials = [material]
        let c = SCNNode(geometry: cap)
        c.position = SCNVector3(0, height, 0)
        n.addChildNode(c)
        return n
    }

    private static func addConeSegment(from a: SIMD3<Float>, to b: SIMD3<Float>, r0: CGFloat, r1: CGFloat, mat: SCNMaterial, parent: SCNNode) {
        let d = b - a
        let len = simd_length(d)
        guard len > 0.001 else { return }
        let cone = SCNCone(topRadius: r1, bottomRadius: r0, height: CGFloat(len))
        cone.radialSegmentCount = 8
        cone.materials = [mat]
        let n = SCNNode(geometry: cone)
        n.simdPosition = (a + b) * 0.5
        n.simdOrientation = TreeMath.quatAligning(from: SIMD3(0,1,0), to: simd_normalize(d))
        parent.addChildNode(n)
    }

    /// Upward-biased jagged polyline.
    private static func makeJaggedPolyline(from base: SIMD3<Float>,
                                           dir: SIMD3<Float>,
                                           length: Float,
                                           upBias: ClosedRange<Float>,
                                           yawJitter: Float,
                                           pitchJitter: Float,
                                           segments: Int,
                                           rng: inout RandomAdaptor) -> [SIMD3<Float>]
    {
        var pts: [SIMD3<Float>] = [base]
        var pos = base
        var forward = simd_normalize(dir)
        let step = max(0.05, length / Float(max(2, segments)))

        for i in 0..<segments {
            let t = Float(i) / Float(max(1, segments - 1))
            var aim = forward
            aim.y += Float.random(in: upBias, using: &rng) * (0.4 + 0.6 * t)
            aim += SIMD3<Float>(
                Float.random(in: -yawJitter...yawJitter, using: &rng),
                Float.random(in: -pitchJitter...pitchJitter, using: &rng),
                Float.random(in: -yawJitter...yawJitter, using: &rng)
            )
            aim = simd_normalize(aim)
            pos += aim * step * Float.random(in: 0.85...1.15, using: &rng)
            pts.append(pos)
            forward = aim
        }
        return pts
    }
}

