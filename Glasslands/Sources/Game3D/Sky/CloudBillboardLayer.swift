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
        var pos: simd_float3
        var size: Float
        var roll: Float
        var atlasIndex: Int
        var opacity: Float
    }

    private struct Cluster { var puffs: [PuffSpec] }

    /// Builds the cloud layer asynchronously (same pattern as CloudDome+Async).
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.18,
        clusterCount: Int = 240,
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        // Cloud-base height and far cap derived from sky distance.
        let layerHeight: Float = max(900, min(Float(radius) * 0.36, 1800))
        let farCap:      Float = max(layerHeight + 1500, Float(radius) * 2.4)

        Task.detached(priority: .userInitiated) {

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

                // Bias directions toward horizon for density, but keep above it.
                @inline(__always)
                func sampleDir(_ s: inout UInt32, minY: Float) -> simd_float3 {
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let k: Float = 3.2
                    let y  = min(0.985, max(minY, 1 - powf(1 - v, k)))
                    let cx = sqrtf(max(0, 1 - y*y))
                    return simd_normalize(simd_float3(sinf(az)*cx, y, cosf(az)*cx))
                }

                // Poisson-ish angle spacing for cluster centres.
                let minSepDeg: Float = 7.0
                let minCos = cosf(minSepDeg * .pi / 180)
                var rays: [simd_float3] = []
                var tries = 0
                while rays.count < clusterCount && tries < clusterCount * 260 {
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

                    // Physical sizes tuned to look big overhead but not full-screen squares.
                    // Core ~350–650 m; mediums ~200–420 m; smalls ~110–240 m.
                    let base = (380.0 + 270.0 * rand(&s))

                    var puffs: [PuffSpec] = []

                    // Core
                    puffs.append(PuffSpec(
                        pos: centre + simd_float3(0, 50, 0),
                        size: base * (1.00 + 0.25 * rand(&s)),
                        roll: 2 * .pi * rand(&s),
                        atlasIndex: Int(rand(&s) * 1024),
                        opacity: 0.97 * farFade
                    ))

                    // Medium ring
                    let mCount = 3 + Int(rand(&s) * 3.9) // 3..6
                    for _ in 0..<mCount {
                        let r     = (120.0 + 200.0 * rand(&s))
                        let t2    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(t2)) + Z * (0.65 * r * sinf(t2))
                        let lift  = 35.0 + 70.0 * rand(&s)
                        puffs.append(PuffSpec(
                            pos: centre + off + simd_float3(0, lift, 0),
                            size: base * (0.60 + 0.28 * rand(&s)),
                            roll: 2 * .pi * rand(&s),
                            atlasIndex: Int(rand(&s) * 1024),
                            opacity: 0.93 * farFade
                        ))
                    }

                    // Small caps
                    let sCount = 4 + Int(rand(&s) * 5.9) // 4..9
                    for _ in 0..<sCount {
                        let r     = (180.0 + 340.0 * rand(&s))
                        let t3    = 2 * .pi * rand(&s)
                        let off   = X * (r * cosf(t3)) + Z * (0.70 * r * sinf(t3))
                        let lift  = 90.0 + 150.0 * rand(&s)
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

            // Clamp UVs; we also inset the UVs when rotating (see transform below).
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

                // Keep upright; face camera around Y.
                let bb = SCNBillboardConstraint()
                bb.freeAxes = .Y
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
