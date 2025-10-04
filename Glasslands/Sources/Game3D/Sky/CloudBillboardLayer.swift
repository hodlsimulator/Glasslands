//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//
//  Key points:
//  • Billboarding is on the parent node; the plane is a child rotated around Z for roll.
//    (No UV rotation, so no edge clamping artefacts.)
//  • Diffuse wrap uses .clampToBorder with a clear border; depth writes disabled.
//  • Horizon‑biased distribution and natural clustering.
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

    /// Builds the billboard layer off the main thread, then delivers the node on the main actor.
    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,     // cos(elevation); 0.0 = horizon, 1.0 = straight up
        clusterCount: Int = 110,        // fewer, larger clusters = closer to reference
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        let layerHeight: Float = max(1100, min(Float(radius) * 0.34, 1800))
        let farCap: Float = max(layerHeight + 2200, Float(radius) * 2.8)

        Task.detached(priority: .userInitiated) {

            func makeSpecs(
                _ n: Int, minY: Float, height: Float, farCap: Float, seed: UInt32
            ) -> [Cluster] {

                @inline(__always) func rand(_ s: inout UInt32) -> Float {
                    s = 1_664_525 &* s &+ 1_013_904_223
                    return Float(s >> 8) * (1.0 / 16_777_216.0)
                }

                var s = seed == 0 ? 1 : seed

                @inline(__always) func sat(_ x: Float) -> Float { max(0, min(1, x)) }

                @inline(__always)
                func biasedY(_ v: Float, minY: Float, k: Float = 3.6) -> Float {
                    let lo = minY, hi: Float = 0.985
                    return lo + (hi - lo) * powf(v, k)
                }

                @inline(__always)
                func minSepCos(forY y: Float, minY: Float) -> Float {
                    let t = sat((y - minY) / (0.985 - minY))
                    let deg = 4.0 + (18.0 - 4.0) * t
                    return cosf(deg * .pi / 180)
                }

                @inline(__always)
                func accept(distance d: Float, height h: Float, farCap: Float) -> Float {
                    let t = sat((d - h) / (farCap - h))
                    return powf(t, 0.85) * 0.9 + 0.06
                }

                var rays: [simd_float3] = []
                var tries = 0
                let hardCap = n * 900

                while rays.count < n && tries < hardCap {
                    tries += 1

                    let u = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)
                    let y  = biasedY(rand(&s), minY: minY)

                    let cx = sqrtf(max(0, 1 - y*y))
                    let d  = simd_normalize(simd_float3(sinf(az)*cx, y, cosf(az)*cx))

                    let t  = height / max(0.001, d.y)
                    if !t.isFinite || t <= 0 { continue }

                    let dist = min(t, farCap)
                    if rand(&s) > accept(distance: dist, height: height, farCap: farCap) {
                        continue
                    }

                    let cosThresh = minSepCos(forY: y, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > cosThresh { ok = false; break }
                    if ok { rays.append(d) }
                }

                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    let anchor = d * t
                    let dist   = length(anchor)

                    let farFade: Float = dist > (0.94 * farCap)
                        ? max(0.25, 1 - (dist - 0.94 * farCap) / (0.06 * farCap))
                        : 1

                    let base = (560.0 + 420.0 * rand(&s))
                             * (0.92 + 0.20 * max(0, min(1, (dist - height) / (farCap - height))))

                    let thickness: Float = 300.0 + 240.0 * rand(&s)

                    var puffs: [PuffSpec] = []

                    let baseLift: Float = 30.0
                    let baseCount = 4 + Int(rand(&s) * 3.5)
                    for _ in 0..<baseCount {
                        let ang = (rand(&s) - 0.5) * (.pi * 0.9)
                        let rad = base * (0.35 + 0.65 * rand(&s))
                        let off = simd_float3(cosf(ang) * rad, 0, sinf(ang) * rad)
                        let pos = anchor + off + simd_float3(0, baseLift, 0)
                        let size = (260.0 + 240.0 * rand(&s)) * (0.85 + 0.30 * rand(&s))
                        let roll = (rand(&s) - 0.5) * (.pi * 2)
                        puffs.append(PuffSpec(pos: pos, size: size, roll: roll,
                                              atlasIndex: Int(rand(&s) * 32.0),
                                              opacity: farFade))
                    }

                    let capCount = 3 + Int(rand(&s) * 2.7)
                    for _ in 0..<capCount {
                        let ang = (rand(&s) - 0.5) * (.pi * 0.7)
                        let rad = base * (0.18 + 0.52 * rand(&s))
                        let off = simd_float3(cosf(ang) * rad, 0, sinf(ang) * rad)
                        let pos = anchor + off + simd_float3(0, baseLift + 0.55 * thickness, 0)
                        let size = (190.0 + 180.0 * rand(&s)) * (0.84 + 0.30 * rand(&s))
                        let roll = (rand(&s) - 0.5) * (.pi * 2)
                        puffs.append(PuffSpec(pos: pos, size: size, roll: roll,
                                              atlasIndex: Int(rand(&s) * 32.0),
                                              opacity: farFade))
                    }

                    if rand(&s) > 0.45 {
                        let skirtCount = 1 + Int(rand(&s) * 2.2)
                        for _ in 0..<skirtCount {
                            let ang = (rand(&s) - 0.5) * (.pi * 1.1)
                            let rad = base * (0.55 + 0.85 * rand(&s))
                            let off = simd_float3(cosf(ang) * rad, 0, sinf(ang) * rad)
                            let pos = anchor + off
                            let size = (210.0 + 220.0 * rand(&s)) * (0.75 + 0.25 * rand(&s))
                            let roll = (rand(&s) - 0.5) * (.pi * 2)
                            puffs.append(PuffSpec(pos: pos, size: size, roll: roll,
                                                  atlasIndex: Int(rand(&s) * 32.0),
                                                  opacity: farFade * 0.92))
                        }
                    }

                    clusters.append(Cluster(puffs: puffs))
                }

                return clusters
            }

            let specs = makeSpecs(
                max(6, min(600, clusterCount)),
                minY: minAltitudeY,
                height: layerHeight,
                farCap: farCap,
                seed: seed
            )

            let atlas = await CloudSpriteTexture.makeAtlas(
                size: 512, seed: seed ^ 0x5A5A_0314, count: 4
            )

            await MainActor.run {
                let root = buildNodes(specs: specs, atlas: atlas)
                completion(root)
            }
        }
    }

    // MARK: - SceneKit assembly (MainActor)

    @MainActor
    private static func buildNodes(specs: [Cluster], atlas: CloudSpriteTexture.Atlas) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        let fragment = """
        #pragma transparent
        #pragma body
        if (_output.color.a < 0.004) { discard_fragment(); }
        """

        let template = SCNMaterial()
        template.lightingModel = .constant
        template.transparencyMode = .aOne       // premultiplied alpha
        template.blendMode = .alpha
        template.readsFromDepthBuffer = true
        template.writesToDepthBuffer = false
        template.isDoubleSided = false
        template.shaderModifiers = [.fragment: fragment]

        // Use clamp (not clampToBorder) to avoid deprecated borderColor.
        template.diffuse.wrapS = .clamp
        template.diffuse.wrapT = .clamp
        template.diffuse.mipFilter = .linear
        template.diffuse.minificationFilter = .linear
        template.diffuse.magnificationFilter = .linear
        template.diffuse.maxAnisotropy = 4.0

        for cl in specs {
            let group = SCNNode()

            for p in cl.puffs {
                // Billboard on a parent node…
                let bb = SCNNode()
                bb.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)
                let b = SCNBillboardConstraint()
                b.freeAxes = .all
                bb.constraints = [b]

                // …with a child plane that rotates around Z to vary orientation.
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let sprite = SCNNode(geometry: plane)
                sprite.eulerAngles.z = p.roll
                sprite.castsShadow = false

                let m = template.copy() as! SCNMaterial
                m.diffuse.contents = atlas.images[p.atlasIndex % max(1, atlas.images.count)]
                m.transparency = CGFloat(p.opacity)
                plane.firstMaterial = m

                bb.addChildNode(sprite)
                group.addChildNode(bb)
            }

            root.addChildNode(group)
        }

        return root
    }
}
