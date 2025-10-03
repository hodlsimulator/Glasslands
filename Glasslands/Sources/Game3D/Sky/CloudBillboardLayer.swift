//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Places hundreds of alpha-puffed billboards on a spherical shell above the
//  player, grouped into clusters. Correct perspective, no lat-long stretching.
//  SceneKit/UIKit work stays on the main actor; heavy maths runs off-main.
//

@preconcurrency import SceneKit
import UIKit
import simd

// MARK: - File-private math (free function so it cannot be @MainActor by inference)

@inline(__always)
fileprivate func cbSmooth01(_ x: Float) -> Float {
    let t = max(0 as Float, min(1 as Float, x))
    return t * t * (3 - 2 * t)
}

// MARK: - Layer

enum CloudBillboardLayer {

    struct PuffSpec {
        var dir: simd_float3
        var size: Float
        var roll: Float
        var atlasIndex: Int
    }

    struct Cluster {
        var puffs: [PuffSpec]
    }

    /// Asynchronously builds the billboard layer.
    /// Heavy maths runs off-main; UIKit/SceneKit hops to MainActor.
    static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.08,
        clusterCount: Int = 120,
        seed: UInt32 = 0x0C10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // Local builder (off-main, pure maths; cannot be @MainActor).
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

                // Place cluster centres on the upper hemisphere with minimum angular separation.
                let minSepDeg: Float = 8.0
                let minCos: Float = cosf(minSepDeg * .pi / 180.0)
                var centres: [simd_float3] = []
                var attempts = 0

                while centres.count < clusterCount && attempts < clusterCount * 200 {
                    attempts += 1

                    // Bias elevation towards mid-sky.
                    let u1 = rand(&s)
                    let t  = rand(&s)
                    let az = (u1 - 0.5) * (2.0 * .pi)
                    let el = (0.08 + 0.84 * t) * (.pi / 2.0)

                    let d = simd_float3(
                        sinf(az) * cosf(el),
                        sinf(el),
                        cosf(az) * cosf(el)
                    )

                    if d.y < minAltitudeY { continue }

                    var ok = true
                    for c in centres where simd_dot(c, d) > minCos {
                        ok = false
                        break
                    }
                    if ok { centres.append(simd_normalize(d)) }
                }

                // For each centre, create 4–8 puffs scattered in the tangent plane.
                var clusters: [Cluster] = []
                clusters.reserveCapacity(centres.count)

                for centre in centres {
                    // Tangent basis (east, north) at this point on the sphere.
                    let up = centre
                    var east = simd_cross(simd_float3(0, 1, 0), up)
                    if simd_length_squared(east) < 1e-6 { east = simd_float3(1, 0, 0) }
                    east = simd_normalize(east)
                    let north = simd_normalize(simd_cross(up, east))

                    var puffs: [PuffSpec] = []
                    let baseSize: Float = 110.0 + 45.0 * rand(&s)      // tuned for ~2 km dome
                    let count = 4 + Int(rand(&s) * 5.0)                // 4–8 puffs per cluster

                    for _ in 0..<count {
                        // Scatter within a small ellipse in tangent space (flatter vertically).
                        let ox = (rand(&s) * 2 - 1) * 0.70
                        let oy = (rand(&s) * 2 - 1) * 0.45
                        let offset = east * ox + north * oy

                        // Slight upward skew so the top is puffier.
                        let skew: Float = 0.10 * rand(&s)

                        // Move from centre along tangent and re-normalise to the sphere.
                        let dir = simd_normalize(up + offset * 0.08 + north * skew * 0.05)

                        // Size falls off from centre; scale with elevation as a perspective cue.
                        let falloff = 1.0 - min(1.0, simd_length(offset)) * 0.28
                        let elevationScale = 0.8 + 0.9 * cbSmooth01(dir.y)
                        let size = baseSize * falloff * elevationScale * (0.88 + 0.24 * rand(&s))

                        let roll = (rand(&s) * 2 - 1) * .pi
                        let atlas = Int(rand(&s) * 4.0)

                        puffs.append(PuffSpec(
                            dir: dir,
                            size: max(8, size),
                            roll: roll,
                            atlasIndex: atlas
                        ))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let specs = buildSpecs(
                clusterCount: clusterCount,
                minAltitudeY: minAltitudeY,
                seed: seed
            )

            let atlas = await CloudSpriteTexture.makeAtlas(size: 256, seed: seed, count: 4)

            let node = await MainActor.run {
                assembleLayer(radius: radius, specs: specs, atlas: atlas)
            }
            await MainActor.run { completion(node) }
        }
    }

    // MARK: - Assembly (MainActor)

    @MainActor
    private static func assembleLayer(
        radius: CGFloat,
        specs: [Cluster],
        atlas: CloudSpriteTexture.Atlas
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Reusable materials for atlas entries (premultiplied alpha; no depth writes).
        var materials: [SCNMaterial] = []
        materials.reserveCapacity(atlas.images.count)
        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = img
            m.emission.contents = img
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
            m.blendMode = .alpha
            m.transparencyMode = .aOne
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
                    x: p.dir.x * Float(radius),
                    y: p.dir.y * Float(radius),
                    z: p.dir.z * Float(radius)
                )
                n.position = pos

                let bb = SCNBillboardConstraint()
                bb.freeAxes = .all
                n.constraints = [bb]

                let mat = materials[p.atlasIndex % materials.count].copy() as! SCNMaterial
                let rot = SCNMatrix4MakeRotation(p.roll, 0, 0, 1)
                mat.diffuse.contentsTransform = rot
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
