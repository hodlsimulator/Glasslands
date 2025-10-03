//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Sprite‑impostor cumulus: hundreds of billboards grouped into clusters,
//  placed on a spherical shell. UIKit/SceneKit on main; maths off‑main.
//

@preconcurrency import SceneKit
import UIKit
import simd

enum CloudBillboardLayer {

    // MARK: Specs

    private struct PuffSpec {
        var dir: simd_float3      // unit direction on the skydome
        var size: Float           // quad size in metres
        var roll: Float           // uv rotation in radians
        var atlasIndex: Int       // which sprite variant
        var opacity: Float        // per-puff fade for depth layering
    }

    private struct Cluster { var puffs: [PuffSpec] }

    // MARK: Build API

    /// Builds the cloud layer asynchronously. Follows the same pattern as CloudDome+Async.
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.22,   // keep comfortably above horizon
        clusterCount: Int = 190,      // dense but still performant
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {

            // Pure-math helper (not actor-isolated) to avoid the global-actor trap.
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

                // Poisson-ish placement of cluster centres on the upper hemisphere.
                let minSepDeg: Float = 7.5
                let minCos:    Float = cosf(minSepDeg * .pi / 180.0)
                var centres: [simd_float3] = []
                var attempts = 0

                while centres.count < clusterCount && attempts < clusterCount * 240 {
                    attempts += 1
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    // Bias elevation to mid-sky. Clamp above horizon.
                    let el = (0.16 + 0.76 * v) * (.pi / 2)

                    var d = simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
                    if d.y < minAltitudeY { d.y = minAltitudeY }
                    d = simd_normalize(d)

                    var ok = true
                    for c in centres where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { centres.append(d) }
                }

                // Build each cumulus as a compact clump:
                //   - 1 large “core”, 2-3 medium, 3-6 small caps around.
                //   - Slight vertical lift for the upper puffs.
                //   - Smaller/clearer near horizon to avoid ground intersections.
                var clusters: [Cluster] = []
                clusters.reserveCapacity(centres.count)

                for centre in centres {
                    let up = simd_normalize(centre)
                    var east = simd_cross(simd_float3(0, 1, 0), up)
                    if simd_length_squared(east) < 1e-6 { east = simd_float3(1, 0, 0) }
                    east = simd_normalize(east)
                    let north = simd_normalize(simd_cross(up, east))

                    let horizonScale = 0.70 + 0.60 * max(0, up.y) // y∈[0..1] => [0.70..1.30]
                    let baseSize = (170.0 + 60.0 * rand(&s)) * horizonScale

                    var puffs: [PuffSpec] = []

                    // Core
                    let core = PuffSpec(
                        dir: up * (1.02),
                        size: baseSize * (1.10 + 0.20 * rand(&s)),
                        roll: 2 * .pi * rand(&s),
                        atlasIndex: Int(rand(&s) * 1024),
                        opacity: 0.96
                    )
                    puffs.append(core)

                    // Medium ring
                    let mediumCount = 2 + Int(rand(&s) * 2.9) // 2..4
                    for _ in 0..<mediumCount {
                        let r = 0.12 + 0.22 * rand(&s)
                        let t = 2 * .pi * rand(&s)
                        let lift = 0.03 + 0.08 * rand(&s)
                        let dir = simd_normalize(up * (1 + lift) + east * (r * cosf(t)) + north * (0.55 * r * sinf(t)))
                        puffs.append(PuffSpec(
                            dir: dir,
                            size: baseSize * (0.70 + 0.25 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.92
                        ))
                    }

                    // Small caps
                    let smallCount = 3 + Int(rand(&s) * 4.9) // 3..7
                    for _ in 0..<smallCount {
                        let r = 0.18 + 0.40 * rand(&s)
                        let t = 2 * .pi * rand(&s)
                        let lift = 0.08 + 0.18 * rand(&s)
                        let dir = simd_normalize(up * (1 + lift) + east * (r * cosf(t)) + north * (0.55 * r * sinf(t)))
                        puffs.append(PuffSpec(
                            dir: dir,
                            size: baseSize * (0.38 + 0.22 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.88
                        ))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let specs = buildSpecs(clusterCount: clusterCount, minAltitudeY: minAltitudeY, seed: seed)

            // Textures and node construction on main.
            let atlas = await CloudSpriteTexture.makeAtlas(size: 256, seed: seed, count: 4)
            let node  = await MainActor.run { buildNode(radius: radius, atlas: atlas, specs: specs) }
            await MainActor.run { completion(node) }
        }
    }

    // MARK: SceneKit (main thread)

    @MainActor
    private static func buildNode(
        radius: CGFloat,
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
            m.diffuse.contents  = img           // IMPORTANT: both diffuse and emission
            m.emission.contents = img
            m.isDoubleSided = true

            // Read depth so the terrain/horizon occludes clouds correctly.
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer  = false

            // Premultiplied alpha setup.
            m.blendMode = .alpha
            m.transparencyMode = .aOne

            // No tiling, no sampling beyond 0..1.
            m.diffuse.wrapS = .clamp;  m.diffuse.wrapT = .clamp
            m.emission.wrapS = .clamp; m.emission.wrapT = .clamp
            // (No borderColor on SCNMaterial — clamping is sufficient.)

            m.diffuse.mipFilter  = .linear
            m.emission.mipFilter = .linear
            materials.append(m)
        }

        // Helper: rotate a material around the UV centre (0.5, 0.5)
        @inline(__always)
        func centredUVRotation(_ angle: Float) -> SCNMatrix4 {
            let t1 = SCNMatrix4MakeTranslation(0.5, 0.5, 0)
            let r  = SCNMatrix4MakeRotation(angle, 0, 0, 1)
            let t2 = SCNMatrix4MakeTranslation(-0.5, -0.5, 0)
            return SCNMatrix4Mult(SCNMatrix4Mult(t1, r), t2)
        }

        for cl in specs {
            let clusterNode = SCNNode()
            for p in cl.puffs {
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let n = SCNNode(geometry: plane)

                // Position on the skydome.
                n.position = SCNVector3(
                    x: p.dir.x * Float(radius),
                    y: p.dir.y * Float(radius),
                    z: p.dir.z * Float(radius)
                )

                // Face the camera but keep an upright “Y”.
                let bb = SCNBillboardConstraint()
                bb.freeAxes = .Y
                n.constraints = [bb]

                let base = (materials[(p.atlasIndex % max(1, materials.count))]).copy() as! SCNMaterial
                let rot  = centredUVRotation(p.roll)
                base.diffuse.contentsTransform  = rot
                base.emission.contentsTransform = rot
                base.transparency = CGFloat(p.opacity)

                plane.firstMaterial = base
                n.castsShadow = false
                clusterNode.addChildNode(n)
            }
            root.addChildNode(clusterNode)
        }

        return root
    }
}
