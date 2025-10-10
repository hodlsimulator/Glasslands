//
//  BarkMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//
//  Builds trunk + continuous, upward-angled branches (tapered tube meshes).
//  Fixes:
//    • Branch/trunk gap: branch bases begin slightly inside the trunk and flare out.
//    • Proportions: thicker primary bases relative to the trunk.
//    • Trunk split: trunk continues above the ring and forks into top primaries.
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

        // The trunk continues above the branch ring a bit (leader), so it looks like it forks.
        let leader = trunkHeight * CGFloat.random(in: 0.12...0.22, using: &rng)
        let trunk = makeTrunk(height: trunkHeight, leader: leader, radius: trunkRadius, material: material)
        group.addChildNode(trunk)

        var anchors: [SIMD3<Float>] = []

        // Ring for the lateral primaries sits high on the trunk.
        let ringY  = trunkHeight * CGFloat.random(in: 0.70...0.85, using: &rng)
        // Start branches slightly INSIDE the trunk to avoid a visible gap.
        // 0.80…0.95 × trunkR means bases are embedded ~5–20% into the trunk.
        let attachR = trunkRadius * CGFloat.random(in: 0.80...0.95, using: &rng)
        let ringN   = max(4, primaryCount)

        let crownH  = max(1.0, totalHeight - trunkHeight)

        // ---------- Lateral primary branches (around a ring)
        for i in 0..<ringN {
            let baseAngle = (2.0 * .pi / CGFloat(ringN)) * CGFloat(i) + CGFloat.random(in: -0.18...0.18, using: &rng)
            let base = SIMD3<Float>(
                Float(attachR * cos(baseAngle)),
                Float(ringY),
                Float(attachR * sin(baseAngle))
            )

            // Initial direction: outward around the trunk, tilted up a bit.
            let tilt = Float(CGFloat.random(in: branchTilt, using: &rng))
            let dir0 = simd_normalize(
                SIMD3<Float>(Float(cos(baseAngle)), 0, Float(sin(baseAngle))) + SIMD3<Float>(0, tan(tilt), 0)
            )

            let len   = Float(crownH) * Float.random(in: 0.60...0.85, using: &rng)

            // Upward, jagged polyline for a natural limb
            let prim = makeJaggedPolyline(from: base,
                                          dir: dir0,
                                          length: len,
                                          upBias: 0.20...0.40,
                                          yawJitter: 0.22,
                                          pitchJitter: 0.18,
                                          segments: Int.random(in: 5...6, using: &rng),
                                          rng: &rng)

            // Thicker base: ~0.50–0.72 of trunk radius, tapering toward the tip.
            let rBase = trunkRadius * CGFloat.random(in: 0.50...0.72, using: &rng)
            // Near the very origin, flare a touch larger to blend into the trunk.
            let rTip  = max(0.016, rBase * 0.38)
            let gPrim = BranchTubeMesh.build(points: prim, rStart: rBase, rEnd: rTip, radialSegments: 10)
            gPrim.materials = [material]
            group.addChildNode(SCNNode(geometry: gPrim))

            // Secondaries growing from the primary, also continuous tubes.
            let secCount = Int.random(in: secondaryPerPrimary, using: &rng)
            for _ in 0..<secCount {
                let idx = Int.random(in: 1..<(prim.count - 1), using: &rng)
                let anchor = prim[idx]
                let ahead  = prim[min(prim.count - 1, idx + 1)]
                let tangent = simd_normalize(ahead - prim[max(0, idx - 1)])
                let side = simd_normalize(simd_cross(tangent, SIMD3<Float>(0,1,0)))
                let out  = simd_normalize(tangent
                                          + side * Float.random(in: -0.7...0.7, using: &rng)
                                          + SIMD3<Float>(0, Float.random(in: 0.12...0.40, using: &rng), 0))

                let len2 = len * Float.random(in: 0.28...0.46, using: &rng)
                let sec = makeJaggedPolyline(from: anchor,
                                             dir: out,
                                             length: len2,
                                             upBias: 0.18...0.32,
                                             yawJitter: 0.28,
                                             pitchJitter: 0.20,
                                             segments: Int.random(in: 3...4, using: &rng),
                                             rng: &rng)

                let r2Base = rBase * CGFloat.random(in: 0.36...0.50, using: &rng)
                let r2Tip  = max(0.012, r2Base * 0.45)
                let gSec = BranchTubeMesh.build(points: sec, rStart: r2Base, rEnd: r2Tip, radialSegments: 10)
                gSec.materials = [material]
                group.addChildNode(SCNNode(geometry: gSec))

                // Leaf anchors on the last third of each secondary
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

        // ---------- Top primaries: the trunk forks near its top leader.
        let topY     = trunkHeight + leader * 0.95
        let forkN    = Int.random(in: 2...3, using: &rng)
        for _ in 0..<forkN {
            // Start very near trunk axis, a little inside so there’s no seam.
            let offsetR = trunkRadius * CGFloat.random(in: 0.0...0.12, using: &rng)
            let angle   = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
            let base = SIMD3<Float>(
                Float(offsetR * cos(angle)),
                Float(topY),
                Float(offsetR * sin(angle))
            )

            // Aim mostly upward with mild outward spread.
            let spread = Float.random(in: 0.18...0.42, using: &rng)
            let dir0 = simd_normalize(SIMD3<Float>(
                cos(Float(angle)) * spread,
                1.0,
                sin(Float(angle)) * spread
            ))

            let len   = Float(crownH) * Float.random(in: 0.45...0.70, using: &rng)
            let prim = makeJaggedPolyline(from: base,
                                          dir: dir0,
                                          length: len,
                                          upBias: 0.20...0.38,
                                          yawJitter: 0.18,
                                          pitchJitter: 0.16,
                                          segments: Int.random(in: 4...5, using: &rng),
                                          rng: &rng)

            let rBase = trunkRadius * CGFloat.random(in: 0.42...0.58, using: &rng)
            let rTip  = max(0.014, rBase * 0.42)
            let gPrim = BranchTubeMesh.build(points: prim, rStart: rBase, rEnd: rTip, radialSegments: 10)
            gPrim.materials = [material]
            group.addChildNode(SCNNode(geometry: gPrim))

            let start = Int((Float(prim.count) * 0.66).rounded(.down))
            for s in start..<prim.count-1 {
                let t = Float.random(in: Float(crownRatio.lowerBound)...Float(crownRatio.upperBound), using: &rng)
                anchors.append(lerp(prim[s], prim[s+1], t))
            }
        }

        // ---------- Flatten to a single bark mesh (one draw)
        let barkMesh = group.flattenedClone()
        barkMesh.name = "TreeBark"
        barkMesh.castsShadow = true
        if let g = barkMesh.geometry {
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 220)]
        }

        return Output(node: barkMesh, leafAnchors: anchors)
    }

    // MARK: - Pieces

    /// Trunk cylinder + a taller “leader” above the ring; small taper at the very top.
    private static func makeTrunk(height: CGFloat, leader: CGFloat, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let totalH = height + leader
        let cyl = SCNCylinder(radius: radius, height: totalH)
        cyl.radialSegmentCount = 14
        cyl.heightSegmentCount = 1
        cyl.materials = [material]

        let n = SCNNode(geometry: cyl)
        n.position = SCNVector3(0, totalH * 0.5, 0)

        // Slim tip so it doesn’t feel blunt.
        let tip = SCNCone(topRadius: radius * 0.66, bottomRadius: radius * 0.92, height: max(0.5, height * 0.10))
        tip.radialSegmentCount = 12
        tip.materials = [material]
        let c = SCNNode(geometry: tip)
        c.position = SCNVector3(0, totalH, 0)
        n.addChildNode(c)
        return n
    }

    /// Upward-biased jagged polyline with mild yaw/pitch jitter.
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
            pos += aim * step * Float.random(in: 0.92...1.12, using: &rng)
            pts.append(pos)
            forward = aim
        }
        return pts
    }

    private static func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
}
