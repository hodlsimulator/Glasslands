//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Plane-based cumulus: hundreds of billboard sprites grouped into clusters,
//  placed on a horizontal cloud layer (fixed altitude). UIKit/SceneKit on main;
//  maths off-main. This gives real perspective: far near the horizon, close overhead.
//

@preconcurrency import SceneKit
import UIKit
import simd

enum CloudBillboardLayer {

    // MARK: Specs

    private struct PuffSpec {
        var pos: simd_float3       // world position on the cloud plane
        var size: Float            // quad size in metres
        var roll: Float            // uv rotation in radians
        var atlasIndex: Int        // which sprite variant
        var opacity: Float         // per-puff fade for soft layering
    }

    private struct Cluster { var puffs: [PuffSpec] }

    // MARK: Build API

    /// Builds the cloud layer asynchronously (same pattern as CloudDome+Async).
    /// - Parameters:
    ///   - radius: skyDistance (used to derive plane height and far cap)
    ///   - minAltitudeY: min elevation for ray directions (keeps above horizon)
    ///   - clusterCount: number of cumulus clusters
    ///   - seed: RNG seed
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.18,
        clusterCount: Int = 240,        // higher coverage
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        // Derive a reasonable cloud-base height and far cap from the sky distance.
        let layerHeight: Float = max(800, min(Float(radius) * 0.38, 2200))   // ~1–2.2 km
        let farCap:      Float = max(layerHeight + 2000, Float(radius) * 2.6) // ~10–12 km

        Task.detached(priority: .userInitiated) {

            // Pure-math helper (not actor-isolated) to avoid global-actor inference.
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

                // We sample directions above the horizon, biasing towards the horizon
                // so the plane is denser there (like the reference image).
                @inline(__always)
                func sampleDirectionAboveHorizon(_ s: inout UInt32, minY: Float) -> simd_float3? {
                    let u = rand(&s)
                    let v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    // Elevation y in [minY, 1], biased towards minY via (1 - (1 - r)^k)
                    let k: Float = 3.2
                    let ry = 1 - powf(1 - v, k)
                    let y  = min(0.985, max(minY, ry))
                    let cosEl = sqrtf(max(0, 1 - y * y))
                    return simd_normalize(simd_float3(sinf(az) * cosEl, y, cosf(az) * cosEl))
                }

                // Simple Poisson-ish keep-out in ANGLE space to avoid identical centres.
                let minSepDeg: Float = 6.5
                let minCos:    Float = cosf(minSepDeg * .pi / 180.0)

                var centres: [simd_float3] = [] // store directions for centre rays
                var attempts = 0
                while centres.count < clusterCount && attempts < clusterCount * 260 {
                    attempts += 1
                    guard let d = sampleDirectionAboveHorizon(&s, minY: minY) else { continue }
                    var ok = true
                    for c in centres where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { centres.append(d) }
                }

                // World axes on the plane
                let planeX = simd_float3(1, 0, 0)
                let planeZ = simd_float3(0, 0, 1)

                // Build each cumulus cluster on the plane by intersecting the camera ray
                // O + t*d with y = height => t = height / d.y
                var clusters: [Cluster] = []
                clusters.reserveCapacity(centres.count)

                for d in centres {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    let centre = d * t // world position on plane
                    let dist   = length(centre)
                    let farFade: Float = dist > (0.9 * farCap) ? max(0.2, 1 - (dist - 0.9 * farCap) / (0.1 * farCap)) : 1

                    // Perspective-independent physical base size in metres.
                    // Big, fluffy: cores ~800–1400 m; mediums ~450–800 m; smalls ~250–480 m.
                    let base = (900.0 + 500.0 * rand(&s))

                    var puffs: [PuffSpec] = []

                    // Core
                    puffs.append(PuffSpec(
                        pos: centre + simd_float3(0, 60, 0),
                        size: base * (1.00 + 0.30 * rand(&s)),
                        roll: 2 * .pi * rand(&s),
                        atlasIndex: Int(rand(&s) * 1024),
                        opacity: 0.97 * farFade
                    ))

                    // Medium ring around the core (elliptical spread, slightly lifted)
                    let mCount = 3 + Int(rand(&s) * 3.9) // 3..6
                    for _ in 0..<mCount {
                        let r     = (140.0 + 260.0 * rand(&s))
                        let theta = 2 * .pi * rand(&s)
                        let off   = planeX * (r * cosf(theta)) + planeZ * (0.65 * r * sinf(theta))
                        let lift  = 40.0 + 80.0 * rand(&s)
                        puffs.append(PuffSpec(
                            pos: centre + off + simd_float3(0, lift, 0),
                            size: base * (0.55 + 0.30 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.93 * farFade
                        ))
                    }

                    // Small caps sprinkled above/around
                    let sCount = 4 + Int(rand(&s) * 5.9) // 4..9
                    for _ in 0..<sCount {
                        let r     = (220.0 + 420.0 * rand(&s))
                        let theta = 2 * .pi * rand(&s)
                        let off   = planeX * (r * cosf(theta)) + planeZ * (0.70 * r * sinf(theta))
                        let lift  = 110.0 + 180.0 * rand(&s)
                        puffs.append(PuffSpec(
                            pos: centre + off + simd_float3(0, lift, 0),
                            size: base * (0.30 + 0.22 * rand(&s)),
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
                minY: max(0.05, minAltitudeY),
                height: layerHeight,
                farCap: farCap,
                seed: seed
            )

            // Build textures and nodes on main.
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

            // Depth: read so the terrain/horizon can occlude; don’t write.
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer  = false

            m.blendMode = .alpha
            m.transparencyMode = .aOne

            // Clamp UVs; rotate around centre in code below.
            m.diffuse.wrapS = .clamp;  m.diffuse.wrapT = .clamp
            m.emission.wrapS = .clamp; m.emission.wrapT = .clamp

            m.diffuse.mipFilter  = .linear
            m.emission.mipFilter = .linear
            materials.append(m)
        }

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

                n.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)

                // Keep clouds upright; face camera around Y.
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
