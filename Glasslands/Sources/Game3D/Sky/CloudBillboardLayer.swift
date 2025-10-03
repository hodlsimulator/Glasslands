//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Plane‑based cumulus: billboard sprites grouped into clusters on a horizontal
//  cloud layer (fixed altitude). Maths is off‑main; SceneKit/UIImage on main.
//  – Full billboarding (.all) so puffs face the camera at any pitch.
//  – Proper blending using premultiplied alpha, no depth writes.
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
        var opacity: Float      // per‑puff fade
    }

    private struct Cluster { var puffs: [PuffSpec] }

    /// Builds the cloud layer asynchronously and returns a ready‑to‑add node.
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.14,    // keep safely above horizon
        clusterCount: Int = 230,       // overall coverage
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        // Cloud‑base height and far cap derived from sky distance.
        let layerHeight: Float = max(1100, min(Float(radius) * 0.34, 1800)) // ~1.1–1.8 km
        let farCap: Float = max(layerHeight + 2000, Float(radius) * 2.6)

        Task.detached(priority: .userInitiated) {
            func buildSpecsOnPlane(
                clusterCount: Int,
                minY: Float,
                height: Float,
                farCap: Float,
                seed: UInt32
            ) -> [Cluster] {
                @inline(__always) func rand(_ s: inout UInt32) -> Float {
                    s = 1_664_525 &* s &+ 1_013_904_223
                    return Float(s >> 8) * (1.0 / 16_777_216.0)
                }

                var s = seed == 0 ? 1 : seed

                // Directions above the horizon, biased toward the horizon (denser rows there).
                @inline(__always)
                func sampleDir(_ s: inout UInt32, minY: Float) -> simd_float3 {
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let k: Float = 3.0
                    let y = min(0.985, max(minY, 1 - powf(1 - v, k)))
                    let cx = sqrtf(max(0, 1 - y*y))
                    return simd_normalize(simd_float3(sinf(az) * cx, y, cosf(az) * cx))
                }

                // Poisson‑ish angular spacing to avoid clumps of cluster centres.
                let minSepDeg: Float = 6.0
                let minCos = cosf(minSepDeg * .pi / 180)
                var rays: [simd_float3] = []
                var tries = 0
                while rays.count < clusterCount && tries < clusterCount * 300 {
                    tries += 1
                    let d = sampleDir(&s, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > minCos {
                        ok = false; break
                    }
                    if ok { rays.append(d) }
                }

                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    // Cluster anchor on the plane and distance fade.
                    let anchor = d * t
                    let dist = length(anchor)
                    let farFade: Float = dist > (0.9 * farCap)
                        ? max(0.2, 1 - (dist - 0.9 * farCap) / (0.1 * farCap))
                        : 1

                    // Physical base size. Big but safe: cores ~500–900 m.
                    let base = (520.0 + 380.0 * rand(&s))

                    // Vertical thickness of the cluster adds a real 3D feel when looking up.
                    let thickness: Float = 260.0 + 220.0 * rand(&s) // ~260–480 m

                    var puffs: [PuffSpec] = []

                    // ---- LAYER 1: Base (heavier) ----
                    let baseLift: Float = 40.0
                    let baseCount = 4 + Int(rand(&s) * 3.9) // 4..7
                    for _ in 0..<baseCount {
                        let ox = (rand(&s) - 0.5) * base * 1.4
                        let oz = (rand(&s) - 0.5) * base
                        let oy = -thickness * 0.2 + rand(&s) * (thickness * 0.5)
                        let size = base * (0.7 + rand(&s) * 0.5) * 0.9
                        puffs.append(PuffSpec(
                            pos: anchor + simd_float3(ox, baseLift + oy, oz),
                            size: size,
                            roll: rand(&s) * .pi * 2,
                            atlasIndex: Int(rand(&s) * 4),
                            opacity: farFade * (0.85 + rand(&s) * 0.15)
                        ))
                    }

                    // ---- LAYER 2: Middle (filling) ----
                    let midCount = 4 + Int(rand(&s) * 4.9) // 4..8
                    for _ in 0..<midCount {
                        let ox = (rand(&s) - 0.5) * base * 1.1
                        let oz = (rand(&s) - 0.5) * base * 0.9
                        let oy = rand(&s) * (thickness * 0.7)
                        let size = base * (0.55 + rand(&s) * 0.4)
                        puffs.append(PuffSpec(
                            pos: anchor + simd_float3(ox, baseLift + oy, oz),
                            size: size,
                            roll: rand(&s) * .pi * 2,
                            atlasIndex: Int(rand(&s) * 4),
                            opacity: farFade
                        ))
                    }

                    // ---- LAYER 3: Cap (lighter touch) ----
                    let capCount = 2 + Int(rand(&s) * 3.0) // 2..4
                    for _ in 0..<capCount {
                        let ox = (rand(&s) - 0.5) * base * 0.7
                        let oz = (rand(&s) - 0.5) * base * 0.6
                        let oy = thickness * 0.6 + rand(&s) * (thickness * 0.5)
                        let size = base * (0.40 + rand(&s) * 0.35)
                        puffs.append(PuffSpec(
                            pos: anchor + simd_float3(ox, baseLift + oy, oz),
                            size: size,
                            roll: rand(&s) * .pi * 2,
                            atlasIndex: Int(rand(&s) * 4),
                            opacity: farFade * 0.92
                        ))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            // Build layout (maths) off‑main.
            let specs = buildSpecsOnPlane(
                clusterCount: clusterCount,
                minY: max(0.0, minAltitudeY),
                height: layerHeight,
                farCap: farCap,
                seed: seed &+ 17
            )

            // Texture atlas and SceneKit node on the main actor.
            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed &+ 33, count: 4)
            let node = await buildLayerNode(specs: specs, atlas: atlas)
            await completion(node)
        }
    }

    @MainActor
    private static func buildLayerNode(specs: [Cluster], atlas: CloudSpriteTexture.Atlas) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Shared material variants (premultiplied alpha).
        var materials: [SCNMaterial] = []
        materials.reserveCapacity(atlas.images.count)
        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = img
            m.emission.contents = img
            m.isDoubleSided = true

            // Depth: read so the terrain/horizon occludes; don’t write.
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer = false

            // Proper alpha blending for premultiplied textures.
            m.blendMode = .alpha
            m.transparencyMode = .aOne

            // Clamp UVs; we also inset when rotating, so no edge sampling.
            m.diffuse.wrapS = .clamp; m.diffuse.wrapT = .clamp
            m.emission.wrapS = .clamp; m.emission.wrapT = .clamp

            m.diffuse.mipFilter = .linear
            m.emission.mipFilter = .linear

            materials.append(m)
        }

        @inline(__always)
        func centredUVTransform(angle: Float, inset: Float = 0.86) -> SCNMatrix4 {
            let t1 = SCNMatrix4MakeTranslation(0.5, 0.5, 0)   // move centre to origin
            let r  = SCNMatrix4MakeRotation(angle, 0, 0, 1)   // rotate
            let s  = SCNMatrix4MakeScale(inset, inset, 1)     // UV inset (wide transparent apron)
            let t2 = SCNMatrix4MakeTranslation(-0.5, -0.5, 0) // move back
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
                let tform = centredUVTransform(angle: p.roll, inset: 0.86)
                mat.diffuse.contentsTransform = tform
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
