//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Plane-based cumulus: billboard sprites grouped into clusters on a horizontal
//  cloud layer (fixed altitude). UIKit/SceneKit on main; maths off-main.
//

@preconcurrency import SceneKit
import UIKit
import simd

enum CloudBillboardLayer {

    private struct PuffSpec {
        var pos: simd_float3    // world position on the cloud plane
        var size: Float         // quad size in metres
        var roll: Float         // UV rotation in radians
        var atlasIndex: Int     // sprite variant
        var opacity: Float      // per-puff fade for soft layering
    }

    private struct Cluster { var puffs: [PuffSpec] }

    /// Builds the cloud layer asynchronously (same pattern as CloudDome+Async).
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.16,     // keep safely above horizon
        clusterCount: Int = 220,        // high coverage
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        // Cloud-base height and far cap derived from sky distance.
        // These numbers give good perspective without giant quads.
        let layerHeight: Float = max(1000, min(Float(radius) * 0.35, 1800))  // ~1.0–1.8 km
        let farCap:      Float = max(layerHeight + 1800, Float(radius) * 2.6)

        Task.detached(priority: .userInitiated) {

            // Pure-math helper (not actor-isolated) to avoid the global-actor trap.
            func buildSpecsOnPlane(
                clusterCount: Int,
                minY: Float,
                height: Float,
                farCap: Float,
                seed: UInt32
            ) -> [Cluster] {

                @inline(__always)
                func rand(_ s: inout UInt32) -> Float {
                    s = 1664525 &* s &+ 1013904223
                    return Float(s >> 8) * (1.0 / 16_777_216.0)
                }

                var s = seed == 0 ? 1 : seed

                // Sample directions above the horizon, biased toward the horizon
                // so we get denser rows there (like the reference).
                @inline(__always)
                func sampleDir(_ s: inout UInt32, minY: Float) -> simd_float3 {
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let k: Float = 3.1 // bias power (bigger => more near horizon)
                    let y  = min(0.985, max(minY, 1 - powf(1 - v, k)))
                    let cx = sqrtf(max(0, 1 - y*y))
                    return simd_normalize(simd_float3(sinf(az)*cx, y, cosf(az)*cx))
                }

                // Poisson-ish angle spacing so clusters don’t stack.
                let minSepDeg: Float = 6.0
                let minCos = cosf(minSepDeg * .pi / 180)
                var rays: [simd_float3] = []
                var tries = 0
                while rays.count < clusterCount && tries < clusterCount * 280 {
                    tries += 1
                    let d = sampleDir(&s, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { rays.append(d) }
                }

                let X = simd_float3(1,0,0), Z = simd_float3(0,0,1)

                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }
                    let centre = d * t
                    let dist   = length(centre)
                    let farFade: Float = dist > (0.9 * farCap) ? max(0.2, 1 - (dist - 0.9*farCap)/(0.1*farCap)) : 1

                    // Physical base size. Big but safe: cores ~420–780 m.
                    let base = (450.0 + 330.0 * rand(&s))

                    var puffs: [PuffSpec] = []

                    // Core (one or two large blobs)
                    let coreCount = 1 + Int(rand(&s) * 1.8) // 1..2
                    for _ in 0..<coreCount {
                        let jitter = X * (20 * (rand(&s)-0.5)) + Z * (20 * (rand(&s)-0.5))
                        puffs.append(PuffSpec(
                            pos: centre + jitter + simd_float3(0, 60, 0),
                            size: base * (1.00 + 0.25 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.97 * farFade
                        ))
                    }

                    // Medium ring (fills the bulk of each cumulus)
                    let mCount = 4 + Int(rand(&s) * 3.9) // 4..7
                    for _ in 0..<mCount {
                        let r     = (130.0 + 220.0 * rand(&s))
                        let t2    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(t2)) + Z * (0.65 * r * sinf(t2))
                        let lift  = 40.0 + 90.0 * rand(&s)
                        puffs.append(PuffSpec(
                            pos: centre + off + simd_float3(0, lift, 0),
                            size: base * (0.62 + 0.30 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.93 * farFade
                        ))
                    }

                    // Small caps (gives the fluffy, stepped top)
                    let sCount = 7 + Int(rand(&s) * 6.9) // 7..13
                    for _ in 0..<sCount {
                        let r     = (190.0 + 360.0 * rand(&s))
                        let t3    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(t3)) + Z * (0.70 * r * sinf(t3))
                        let lift  = 100.0 + 180.0 * rand(&s)
                        puffs.append(PuffSpec(
                            pos: centre + off + simd_float3(0, lift, 0),
                            size: base * (0.34 + 0.20 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.88 * farFade
                        ))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let specs = buildSpecsOnPlane(
                clusterCount: clusterCount,
                minY: max(0.06, minAltitudeY),
                height: layerHeight,
                farCap: farCap,
                seed: seed
            )

            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed, count: 4)
            let node  = await MainActor.run { buildNode(atlas: atlas, specs: specs) }
            await MainActor.run { completion(node) }
        }
    }

    // MARK: SceneKit (main thread)

    @MainActor
    private static func buildNode(
        atlas: CloudSpriteTexture.Atlas,
        specs: [Cluster]
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Shared material variants (premultiplied alpha).
        var materials: [SCNMaterial] = []
        materials.reserveCapacity(atlas.images.count)

        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents  = img
            m.emission.contents = img
            m.isDoubleSided = true

            // Depth: read so the terrain/horizon occludes; don’t write.
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer  = false

            m.blendMode = .alpha
            m.transparencyMode = .aOne

            // Clamp UVs; we also inset when rotating, so no edge sampling.
            m.diffuse.wrapS = .clamp;  m.diffuse.wrapT = .clamp
            m.emission.wrapS = .clamp; m.emission.wrapT = .clamp

            m.diffuse.mipFilter  = .linear
            m.emission.mipFilter = .linear
            materials.append(m)
        }

        @inline(__always)
        func centredUVTransform(angle: Float, inset: Float = 0.88) -> SCNMatrix4 {
            let t1 = SCNMatrix4MakeTranslation(0.5, 0.5, 0)
            let r  = SCNMatrix4MakeRotation(angle, 0, 0, 1)
            let s  = SCNMatrix4MakeScale(inset, inset, 1)
            let t2 = SCNMatrix4MakeTranslation(-0.5, -0.5, 0)
            return SCNMatrix4Mult(SCNMatrix4Mult(SCNMatrix4Mult(t1, r), s), t2)
        }

        for cl in specs {
            let clusterNode = SCNNode()
            for p in cl.puffs {
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let n = SCNNode(geometry: plane)

                n.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)

                // Keep upright; face camera around Y.
                let bb = SCNBillboardConstraint()
                bb.freeAxes = .Y
                n.constraints = [bb]

                let mat = (materials[(p.atlasIndex % max(1, materials.count))]).copy() as! SCNMaterial
                let tform  = centredUVTransform(angle: p.roll, inset: 0.88)
                mat.diffuse.contentsTransform  = tform
                mat.emission.contentsTransform = tform
                mat.transparency = CGFloat(p.opacity)

                plane.firstMaterial = mat
                n.castsShadow = false
                clusterNode.addChildNode(n)
            }
            root.addChildNode(clusterNode)
        }

        return root
    }
}
