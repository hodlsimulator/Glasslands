//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites. Uses premultiplied alpha,
//  angle‑safe UV transforms (no clamping crop), and a tiny fragment cutoff
//  to avoid any halo from far mips.
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

    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.14,
        clusterCount: Int = 210,
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        let layerHeight: Float = max(1100, min(Float(radius) * 0.34, 1800))
        let farCap: Float = max(layerHeight + 2000, Float(radius) * 2.6)

        Task.detached(priority: .userInitiated) {
            func makeSpecs(
                _ n: Int,
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

                // Directions above the horizon, biased toward horizon.
                @inline(__always)
                func sampleDir(_ s: inout UInt32, minY: Float) -> simd_float3 {
                    let u = rand(&s), v = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let k: Float = 3.0
                    let y = min(0.985, max(minY, 1 - powf(1 - v, k)))
                    let cx = sqrtf(max(0, 1 - y*y))
                    return simd_normalize(simd_float3(sinf(az) * cx, y, cosf(az) * cx))
                }

                // Poisson‑ish angular spacing to avoid cluster overlaps.
                let minSepDeg: Float = 6.0
                let minCos = cosf(minSepDeg * .pi / 180)
                var rays: [simd_float3] = []
                var tries = 0
                while rays.count < n && tries < n * 300 {
                    tries += 1
                    let d = sampleDir(&s, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > minCos { ok = false; break }
                    if ok { rays.append(d) }
                }

                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    let anchor = d * t
                    let dist = length(anchor)
                    let farFade: Float = dist > (0.9 * farCap)
                        ? max(0.2, 1 - (dist - 0.9 * farCap) / (0.1 * farCap))
                        : 1

                    let base = (520.0 + 380.0 * rand(&s))
                    let thickness: Float = 260.0 + 220.0 * rand(&s)

                    var puffs: [PuffSpec] = []

                    // Base
                    let baseLift: Float = 40.0
                    let baseCount = 4 + Int(rand(&s) * 3.9)
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
                            opacity: farFade * (0.88 + rand(&s) * 0.12)
                        ))
                    }

                    // Fill
                    let midCount = 4 + Int(rand(&s) * 4.9)
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

                    // Cap
                    let capCount = 2 + Int(rand(&s) * 3.0)
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
                            opacity: farFade * 0.94
                        ))
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let layout = makeSpecs(
                clusterCount,
                minY: max(0.0, minAltitudeY),
                height: layerHeight,
                farCap: farCap,
                seed: seed &+ 17
            )

            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed &+ 33, count: 4)
            let node = await buildLayerNode(specs: layout, atlas: atlas)
            await completion(node)
        }
    }

    @MainActor
    private static func buildLayerNode(specs: [Cluster], atlas: CloudSpriteTexture.Atlas) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Tiny discard to remove any residual far‑mip noise.
        let fragment = """
        #pragma transparent
        #pragma body
        if (_output.color.a < 0.004) { discard_fragment(); }
        """

        // Shared material variants (premultiplied alpha).
        var materials: [SCNMaterial] = []
        materials.reserveCapacity(atlas.images.count)

        for img in atlas.images {
            let m = SCNMaterial()
            m.lightingModel = .constant

            // Colour+alpha are in the diffuse (premultiplied).
            m.diffuse.contents = img
            m.transparencyMode = .aOne
            m.blendMode = .alpha

            // No extra mask — avoids double‑masking artefacts.
            m.transparent.contents = nil

            // Depth: read so terrain can occlude; don’t write.
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer = false

            // Clamp is fine because we keep rotated UVs inside [0,1].
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.diffuse.mipFilter = .linear
            m.diffuse.minificationFilter = .linear
            m.diffuse.magnificationFilter = .linear

            m.isDoubleSided = false
            m.shaderModifiers = [.fragment: fragment]
            materials.append(m)
        }

        // Angle‑safe UV transform: for a given roll angle θ, the largest
        // scale that *guarantees* the rotated square stays inside [0,1]
        // is 1 / (|cosθ| + |sinθ|). We add a small margin (0.98).
        @inline(__always)
        func insetForAngle(_ a: Float) -> Float {
            let denom = max(1.0, abs(cos(a)) + abs(sin(a)))   // 1 .. √2
            let s = 0.98 / denom                               // ~0.98 .. ~0.693
            return max(0.65, min(0.98, s))
        }

        @inline(__always)
        func centredUVTransform(angle: Float, inset: Float) -> SCNMatrix4 {
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

                let bb = SCNBillboardConstraint()
                bb.freeAxes = .all
                n.constraints = [bb]

                let mat = (materials[(p.atlasIndex % max(1, materials.count))]).copy() as! SCNMaterial

                let inset = insetForAngle(p.roll) // <<< the fix
                let tform = centredUVTransform(angle: p.roll, inset: inset)
                mat.diffuse.contentsTransform = tform
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
