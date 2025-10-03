//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Places hundreds of alpha‑puffed billboards on a spherical shell above the
//  player, grouped into clusters. Correct perspective, no lat‑long stretching.
//  All SceneKit/UIKit work is executed on the main actor (c77df77 style).
//

@preconcurrency import SceneKit
import UIKit
import simd

@MainActor
enum CloudBillboardLayer {

    /// Build the cumulus layer asynchronously.
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.08,
        clusterCount: Int = 120,
        seed: UInt32 = 0x0C10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // 1) Compute positions off-main.
            let specs = buildSpecs(
                clusterCount: clusterCount,
                minAltitudeY: minAltitudeY,
                seed: seed
            )

            // 2) Create textures (runs on main internally).
            let atlas = await CloudSpriteTexture.makeAtlas(size: 256, seed: seed, count: 4)

            // 3) Assemble SceneKit nodes on the main actor.
            let node = await MainActor.run {
                assembleLayer(radius: radius, specs: specs, atlas: atlas)
            }
            await MainActor.run { completion(node) }
        }
    }

    // MARK: - Spec generation (off-main)

    struct PuffSpec {
        var dir: simd_float3
        var size: Float
        var roll: Float
        var atlasIndex: Int
    }

    struct Cluster {
        var centre: simd_float3
        var puffs: [PuffSpec]
    }

    nonisolated private static func buildSpecs(
        clusterCount: Int,
        minAltitudeY: Float,
        seed: UInt32
    ) -> [Cluster] {

        @inline(__always) func rand(_ s: inout UInt32) -> Float {
            s = 1664525 &* s &+ 1013904223
            return Float(s >> 8) * (1.0 / 16_777_216.0)
        }
        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
            min(hi, max(lo, x))
        }

        var s = seed == 0 ? 1 : seed

        let minSepDeg: Float = 8.0
        let minCos: Float = cosf(minSepDeg * Float.pi / Float(180.0))

        var centres: [simd_float3] = []
        var attempts = 0
        while centres.count < clusterCount && attempts < clusterCount * 200 {
            attempts += 1
            // Upper hemisphere with altitude bias towards mid-sky.
            let u1 = rand(&s)
            let t  = rand(&s)
            let az = (u1 - Float(0.5)) * (Float(2.0) * Float.pi)
            let el = (Float(0.08) + Float(0.84) * t) * (Float.pi / Float(2.0))
            let d  = simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
            if d.y < minAltitudeY { continue }

            var ok = true
            for c in centres {
                if simd_dot(c, d) > minCos { ok = false; break }
            }
            if ok { centres.append(simd_normalize(d)) }
        }

        // For each centre, create several puffs in its tangent plane.
        var clusters: [Cluster] = []
        clusters.reserveCapacity(centres.count)

        for centre in centres {
            var puffs: [PuffSpec] = []
            let baseSize: Float = 110.0 + 45.0 * rand(&s) // tuned for ~2 km dome
            let count = 4 + Int(rand(&s) * 5.0)          // 4–8 puffs per cluster

            // Tangent basis (east,north) on the sphere.
            let up = centre
            var east = simd_cross(simd_float3(0, 1, 0), up)
            if simd_length_squared(east) < 1e-6 { east = simd_float3(1, 0, 0) }
            east = simd_normalize(east)
            let north = simd_normalize(simd_cross(up, east))

            for _ in 0..<count {
                let r = (Float(0.12) + Float(0.42) * rand(&s)) * baseSize
                let a = rand(&s) * (Float.pi * Float(2.0))
                let off = east  * (cosf(a) * r * Float(0.012))
                         + north * (sinf(a) * r * Float(0.010))
                let d = simd_normalize(up + off)

                // Perspective tweak: smaller towards the horizon.
                let zen = clampf((up.y - Float(0.08)) / (Float(0.92) - Float(0.08)), 0, 1)
                let scale = Float(0.65) + Float(0.60) * (1.0 - zen)

                let size = (Float(0.65) + Float(0.55) * rand(&s)) * baseSize * scale
                let roll = rand(&s) * (Float.pi * Float(2.0))
                let atlasIndex = Int(rand(&s) * Float(4.0))

                puffs.append(PuffSpec(dir: d, size: size, roll: roll, atlasIndex: atlasIndex))
            }

            // Optional small cap on top.
            if rand(&s) < Float(0.65) {
                let dTop = simd_normalize(up + north * Float(0.003))
                puffs.append(
                    PuffSpec(
                        dir: dTop,
                        size: baseSize * Float(0.55),
                        roll: rand(&s) * (Float.pi * Float(2.0)),
                        atlasIndex: Int(rand(&s) * Float(4.0))
                    )
                )
            }

            clusters.append(Cluster(centre: centre, puffs: puffs))
        }

        return clusters
    }

    // MARK: - Assembly (main actor)

    @MainActor
    private static func assembleLayer(radius: CGFloat, specs: [Cluster], atlas: CloudSpriteTexture.Atlas) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Reusable materials for atlas entries.
        var materials: [SCNMaterial] = []
        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = img
            m.emission.contents = img
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
            m.blendMode = .alpha
            m.diffuse.mipFilter = .linear
            m.emission.mipFilter = .linear
            materials.append(m)
        }

        for cl in specs {
            let clusterNode = SCNNode()
            for p in cl.puffs {
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let n = SCNNode(geometry: plane)

                let pos = SCNVector3(
                    x: cl.centre.x * Float(radius),
                    y: cl.centre.y * Float(radius),
                    z: cl.centre.z * Float(radius)
                )
                n.position = pos
                n.constraints = [SCNBillboardConstraint()]

                let mat = materials[p.atlasIndex % materials.count].copy() as! SCNMaterial
                mat.transparency = 0.985
                let rot = SCNMatrix4MakeRotation(p.roll, 0, 0, 1)
                mat.diffuse.contentsTransform = rot
                mat.emission.contentsTransform = rot
                plane.firstMaterial = mat

                clusterNode.addChildNode(n)
            }
            root.addChildNode(clusterNode)
        }

        return root
    }
}
