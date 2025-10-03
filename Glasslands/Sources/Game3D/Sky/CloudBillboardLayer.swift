//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Places hundreds of soft billboards on a spherical shell above the player,
//  grouped into clusters. SceneKit/UIKit runs on the main actor; only maths is off-main.
//

@preconcurrency import SceneKit
import UIKit
import simd

enum CloudBillboardLayer {

    // One small puff within a cluster.
    private struct PuffSpec {
        var dir: simd_float3      // unit direction from origin to sphere
        var size: Float           // world-space size of the quad (metres)
        var roll: Float           // random sprite roll in radians
        var atlasIndex: Int       // which variant texture to use
    }

    // A mini-group of puffs.
    private struct Cluster {
        var puffs: [PuffSpec]
    }

    /// Asynchronously builds the billboard layer.
    /// Heavy maths runs inside the detached task via a local helper (not main-actor-isolated).
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.08,
        clusterCount: Int = 160,
        seed: UInt32 = 0x0C10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {

            // Local, pure-math builder — avoids global-actor inference (mirrors 67df024 pattern).
            func buildSpecs(
                clusterCount: Int,
                minAltitudeY: Float,
                seed: UInt32
            ) -> [Cluster] {

                @inline(__always)
                func rand(_ s: inout UInt32) -> Float {
                    s = 1664525 &* s &+ 1013904223
                    return Float(s >> 8) * (1.0 / 16_777_216.0)
                }

                var s = seed == 0 ? 1 : seed

                // Poisson-like distribution of cluster centres across the upper hemisphere.
                let minSepDeg: Float = 8.0
                let minCos:    Float = cosf(minSepDeg * .pi / 180.0)
                var centres: [simd_float3] = []
                var attempts = 0

                while centres.count < clusterCount && attempts < clusterCount * 200 {
                    attempts += 1

                    // Bias elevation towards mid-sky; keep above horizon.
                    let u1 = rand(&s)
                    let t  = rand(&s)
                    let az = (u1 - 0.5) * (2.0 * .pi)
                    let el = (0.10 + 0.80 * t) * (.pi / 2.0)

                    let d = simd_float3(
                        sinf(az) * cosf(el),
                        sinf(el),
                        cosf(az) * cosf(el)
                    )
                    if d.y < minAltitudeY { continue }

                    var ok = true
                    for c in centres where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { centres.append(simd_normalize(d)) }
                }

                // For each centre, create 4–8 puffs scattered in the tangent plane.
                var clusters: [Cluster] = []
                clusters.reserveCapacity(centres.count)

                for centre in centres {
                    let up = centre
                    var east = simd_cross(simd_float3(0, 1, 0), up)
                    if simd_length_squared(east) < 1e-6 { east = simd_float3(1, 0, 0) }
                    east = simd_normalize(east)
                    let north = simd_normalize(simd_cross(up, east))

                    var puffs: [PuffSpec] = []
                    let baseSize: Float = 110.0 + 45.0 * rand(&s)  // tuned for ~4.6 km skydome

                    let count = 4 + Int(rand(&s) * 5.0)            // 4–8 puffs per cluster
                    for _ in 0..<count {
                        // Slightly squashed Gaussian in tangent plane for a cumulus clump shape.
                        let r     = (0.15 + 0.45 * rand(&s))
                        let theta = 2 * .pi * rand(&s)
                        let x     = r * cosf(theta)
                        let y     = (0.5 * r) * sinf(theta)

                        // Gentle vertical lift so clusters aren’t perfectly flat.
                        let lift  = 0.06 * (rand(&s) - 0.5)

                        let dir   = simd_normalize(up * (1.0 + lift) + east * x + north * y)
                        let scale = 0.75 + 0.75 * rand(&s)
                        let size  = baseSize * scale
                        let roll  = 2 * .pi * rand(&s)
                        let aidx  = Int(rand(&s) * 1024)  // modulo against atlas count later

                        puffs.append(PuffSpec(dir: dir, size: size, roll: roll, atlasIndex: aidx))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let specs = buildSpecs(clusterCount: clusterCount, minAltitudeY: minAltitudeY, seed: seed)

            // Textures on main (UIImage), then node construction on main.
            let atlas = await CloudSpriteTexture.makeAtlas(size: 256, seed: seed, count: 4)
            let node  = await MainActor.run { buildNode(radius: radius, atlas: atlas, specs: specs) }
            await MainActor.run { completion(node) }
        }
    }

    // Main-thread SceneKit
    @MainActor
    private static func buildNode(
        radius: CGFloat,
        atlas: CloudSpriteTexture.Atlas,
        specs: [Cluster]
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990  // drawn before world geometry

        // Reusable premultiplied-alpha materials.
        var materials: [SCNMaterial] = []
        materials.reserveCapacity(atlas.images.count)

        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents  = img
            m.emission.contents = img
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
            m.blendMode = .alpha
            m.transparencyMode = .aOne   // premultiplied
            m.diffuse.mipFilter  = .linear
            m.emission.mipFilter = .linear
            materials.append(m)
        }

        for cl in specs {
            let clusterNode = SCNNode()
            for p in cl.puffs {
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let n = SCNNode(geometry: plane)

                // Place on spherical shell.
                n.position = SCNVector3(
                    x: p.dir.x * Float(radius),
                    y: p.dir.y * Float(radius),
                    z: p.dir.z * Float(radius)
                )

                // Always face the camera.
                let bb = SCNBillboardConstraint()
                bb.freeAxes = .all
                n.constraints = [bb]

                let mat = (materials[(p.atlasIndex % max(1, materials.count))]).copy() as! SCNMaterial
                // Random sprite roll.
                let rot = SCNMatrix4MakeRotation(p.roll, 0, 0, 1)
                mat.diffuse.contentsTransform  = rot
                mat.emission.contentsTransform = rot
                mat.transparency = 0.985

                plane.firstMaterial = mat
                n.castsShadow = false
                clusterNode.addChildNode(n)
            }
            root.addChildNode(clusterNode)
        }

        return root
    }
}
