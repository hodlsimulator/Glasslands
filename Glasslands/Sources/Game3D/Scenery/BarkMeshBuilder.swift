//
//  BarkMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//
//  Builds trunk + continuous, upward-angled branches (tapered tube meshes).
//  Returns a flattened bark mesh (single draw) and anchor points for leaves.
//

import SceneKit
import simd
import CoreGraphics

enum BarkMeshBuilder {

    struct Output {
        let node: SCNNode
        let leafAnchors: [SIMD3<Float>]
    }

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
        let trunk = makeTrunk(height: trunkHeight, radius: trunkRadius, material: material)
        group.addChildNode(trunk)

        var anchors: [SIMD3<Float>] = []
        let crownH = max(1.0, totalHeight - trunkHeight)
        let startY = trunkHeight * CGFloat.random(in: 0.62...0.78, using: &rng)
        let ringR  = max(trunkRadius * 1.2, totalHeight * 0.05)
        let ringN  = max(4, primaryCount)

        for i in 0..<ringN {
            let baseAngle = (2.0 * .pi / CGFloat(ringN)) * CGFloat(i) + CGFloat.random(in: -0.18...0.18, using: &rng)
            let base      = SIMD3<Float>(Float(ringR * cos(baseAngle)), Float(startY), Float(ringR * sin(baseAngle)))

            let len   = Float(crownH) * Float.random(in: 0.60...0.85, using: &rng)
            let tilt  = Float(CGFloat.random(in: branchTilt, using: &rng))
            let dir0  = simd_normalize(SIMD3<Float>(Float(cos(baseAngle)), 0, Float(sin(baseAngle))) + SIMD3<Float>(0, tan(tilt), 0))

            // Upward, jagged primary polyline
            let prim = makeJaggedPolyline(from: base,
                                          dir: dir0,
                                          length: len,
                                          upBias: 0.20...0.40,
                                          yawJitter: 0.25,
                                          pitchJitter: 0.18,
                                          segments: Int.random(in: 5...6, using: &rng),
                                          rng: &rng)

            // Continuous branch tube (taper rBase → rTip)
            let rBase = trunkRadius * CGFloat.random(in: 0.28...0.38, using: &rng)
            let rTip  = max(0.015, rBase * 0.35)
            let gPrim = BranchTubeMesh.build(points: prim, rStart: rBase, rEnd: rTip, radialSegments: 8)
            gPrim.materials = [material]
            group.addChildNode(SCNNode(geometry: gPrim))

            // Secondary branches
            let secCount = Int.random(in: secondaryPerPrimary, using: &rng)
            for _ in 0..<secCount {
                let idx = Int.random(in: 1..<(prim.count - 1), using: &rng)
                let anchor = prim[idx]
                let ahead  = prim[min(prim.count - 1, idx + 1)]
                let tangent = simd_normalize(ahead - prim[max(0, idx - 1)])
                let side = simd_normalize(simd_cross(tangent, SIMD3<Float>(0,1,0)))
                let out  = simd_normalize(tangent + side * Float.random(in: -0.7...0.7, using: &rng) + SIMD3<Float>(0, Float.random(in: 0.1...0.4, using: &rng), 0))

                let len2 = len * Float.random(in: 0.25...0.45, using: &rng)
                let sec = makeJaggedPolyline(from: anchor,
                                             dir: out,
                                             length: len2,
                                             upBias: 0.18...0.32,
                                             yawJitter: 0.30,
                                             pitchJitter: 0.20,
                                             segments: Int.random(in: 3...4, using: &rng),
                                             rng: &rng)

                let r2Base = rBase * CGFloat.random(in: 0.26...0.36, using: &rng)
                let r2Tip  = max(0.012, r2Base * 0.40)
                let gSec = BranchTubeMesh.build(points: sec, rStart: r2Base, rEnd: r2Tip, radialSegments: 8)
                gSec.materials = [material]
                group.addChildNode(SCNNode(geometry: gSec))

                // Leaf anchors along the last third of the secondary
                let start = Int((Float(sec.count) * 0.66).rounded(.down))
                for s in start..<sec.count-1 {
                    let t = Float.random(in: Float(crownRatio.lowerBound)...Float(crownRatio.upperBound), using: &rng)
                    anchors.append(lerp(sec[s], sec[s+1], t))
                }
            }

            // Leaf anchors on the primary tip region
            let start = Int((Float(prim.count) * 0.66).rounded(.down))
            for s in start..<prim.count-1 {
                let t = Float.random(in: Float(crownRatio.lowerBound)...Float(crownRatio.upperBound), using: &rng)
                anchors.append(lerp(prim[s], prim[s+1], t))
            }
        }

        let barkMesh = group.flattenedClone()   // single draw for all bark
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
            pos += aim * step * Float.random(in: 0.90...1.12, using: &rng)
            pts.append(pos)
            forward = aim
        }
        return pts
    }

    private static func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
}
