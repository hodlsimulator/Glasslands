//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Plane-based cumulus: billboard sprites grouped into clusters on a horizontal
//  cloud layer (fixed altitude). UIKit/SceneKit on main; maths off-main.
//  – Full billboarding (.all) so puffs face the camera at any pitch (no rectangles).
//  – Real “thickness”: each cluster spans multiple vertical layers (base/mid/cap).
//

@preconcurrency import SceneKit
import UIKit
import simd

enum CloudBillboardLayer {

    private struct PuffSpec {
        var pos: simd_float3    // world position
        var size: Float         // quad size in metres
        var roll: Float         // UV rotation in radians
        var atlasIndex: Int     // sprite variant
        var opacity: Float      // per-puff fade
    }

    private struct Cluster { var puffs: [PuffSpec] }

    /// Builds the cloud layer asynchronously (mirrors CloudDome+Async pattern).
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.14,      // keep safely above horizon
        clusterCount: Int = 230,         // high coverage
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        // Cloud-base height and far cap derived from sky distance.
        let layerHeight: Float = max(1100, min(Float(radius) * 0.34, 1800)) // ~1.1–1.8 km
        let farCap:      Float = max(layerHeight + 2000, Float(radius) * 2.6)

        Task.detached(priority: .userInitiated) {

            // Pure maths (not actor-isolated)
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

                // Directions above the horizon, biased toward the horizon (denser rows there).
                @inline(__always)
                func sampleDir(_ s: inout UInt32, minY: Float) -> simd_float3 {
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let k: Float = 3.0
                    let y  = min(0.985, max(minY, 1 - powf(1 - v, k)))
                    let cx = sqrtf(max(0, 1 - y*y))
                    return simd_normalize(simd_float3(sinf(az) * cx, y, cosf(az) * cx))
                }

                // Poisson-ish angle spacing for cluster centres.
                let minSepDeg: Float = 6.0
                let minCos = cosf(minSepDeg * .pi / 180)
                var rays: [simd_float3] = []
                var tries = 0
                while rays.count < clusterCount && tries < clusterCount * 300 {
                    tries += 1
                    let d = sampleDir(&s, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { rays.append(d) }
                }

                // Plane axes
                let X = simd_float3(1,0,0), Z = simd_float3(0,0,1)

                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    // Cluster “anchor” on plane and distance fade.
                    let anchor = d * t
                    let dist   = length(anchor)
                    let farFade: Float = dist > (0.9 * farCap) ? max(0.2, 1 - (dist - 0.9*farCap)/(0.1*farCap)) : 1

                    // Physical base size. Big but safe: cores ~500–900 m.
                    let base = (520.0 + 380.0 * rand(&s))
                    // Vertical thickness of the cluster (adds 3D feel when looking up).
                    let thickness: Float = 260.0 + 220.0 * rand(&s) // ~260–480 m

                    var puffs: [PuffSpec] = []

                    // ---- LAYER 1: Base (heavier) ----
                    let baseLift: Float = 40.0
                    let baseCount = 4 + Int(rand(&s) * 3.9) // 4..7
                    for _ in 0..<baseCount {
                        let r     = 110.0 + 210.0 * rand(&s)
                        let th    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(th)) + Z * (0.70 * r * sinf(th))
                        let vy    = baseLift + 0.35 * thickness * rand(&s)
                        puffs.append(PuffSpec(
                            pos: anchor + off + simd_float3(0, vy, 0),
                            size: base * (0.70 + 0.35 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 4096),
                            opacity: 0.95 * farFade
                        ))
                    }

                    // ---- LAYER 2: Mid (core blobs) ----
                    let midLift: Float = 0.45 * thickness
                    let coreCount = 2 + Int(rand(&s) * 2.2) // 2..4
                    for _ in 0..<coreCount {
                        let jitter = X * (30 * (rand(&s)-0.5)) + Z * (30 * (rand(&s)-0.5))
                        let vy     = midLift + 0.20 * thickness * rand(&s)
                        puffs.append(PuffSpec(
                            pos: anchor + jitter + simd_float3(0, vy, 0),
                            size: base * (1.00 + 0.30 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 4096),
                            opacity: 0.98 * farFade
                        ))
                    }

                    // ---- LAYER 3: Cap (fluffy top) ----
                    let capLift: Float = 0.70 * thickness
                    let capCount = 7 + Int(rand(&s) * 6.9) // 7..13
                    for _ in 0..<capCount {
                        let r     = 160.0 + 320.0 * rand(&s)
                        let th    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(th)) + Z * (0.75 * r * sinf(th))
                        let vy    = capLift + 0.30 * thickness * rand(&s)
                        puffs.append(PuffSpec(
                            pos: anchor + off + simd_float3(0, vy, 0),
                            size: base * (0.36 + 0.22 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 4096),
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

            // Textures on main; then node construction on main.
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
        func centredUVTransform(angle: Float, inset: Float = 0.86) -> SCNMatrix4 {
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

                // FULL billboarding so puffs face the camera from any angle.
                let bb = SCNBillboardConstraint()
                bb.freeAxes = .all
                n.constraints = [bb]

                let mat = (materials[(p.atlasIndex % max(1, materials.count))]).copy() as! SCNMaterial
                let tform  = centredUVTransform(angle: p.roll, inset: 0.86)
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
