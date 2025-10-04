//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//  • Horizon‑biased distribution (more far, fewer near).
//  • Variable Poisson spacing (tight near horizon, wide near zenith).
//  • Distance acceptance (prefer far intersections).
//  • Angle‑safe UV transforms (no clamp cropping).
//  • Premultiplied‑alpha diffuse with tiny halo cutoff.
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
        let layerHeight: Float = max(1100, min(Float(radius) * 0.34, 1800))  // cloud base (m)
        let farCap: Float = max(layerHeight + 2200, Float(radius) * 2.8)     // max view distance on the layer

        Task.detached(priority: .userInitiated) {

            // MARK: Layout

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

                @inline(__always) func saturate(_ x: Float) -> Float { max(0, min(1, x)) }

                // Horizon‑biased y sampler:
                //   y in [minY, 0.985], with many more samples near minY (horizon).
                //   k > 1 gives the bias we want.
                @inline(__always)
                func biasedY(_ v: Float, minY: Float, k: Float = 3.2) -> Float {
                    let lo = minY, hi: Float = 0.985
                    return lo + (hi - lo) * powf(v, k)    // v∈[0,1] -> mostly small y
                }

                // For Poisson spacing, vary required angular separation with elevation:
                //   tiny near horizon (pack more), big near zenith (pack fewer).
                @inline(__always)
                func minSepCos(forY y: Float, minY: Float) -> Float {
                    let t = saturate((y - minY) / (0.985 - minY)) // 0 at horizon -> 1 at zenith
                    let deg = 3.0 + (14.0 - 3.0) * t              // 3° .. 14°
                    return cosf(deg * .pi / 180)
                }

                // Acceptance vs distance along the layer plane: favour far (> mid range).
                @inline(__always)
                func acceptProbability(distance d: Float, height h: Float, farCap: Float) -> Float {
                    let t = saturate((d - h) / (farCap - h))   // 0 near base .. 1 far
                    return powf(t, 0.8) * 0.85 + 0.10          // keep a small chance for near
                }

                // Generate weighted/Poisson rays.
                var rays: [simd_float3] = []
                var tries = 0
                let hardCap = n * 900

                while rays.count < n && tries < hardCap {
                    tries += 1

                    // Sample azimuth uniformly.
                    let u = rand(&s)
                    let az = (u - 0.5) * (2 * .pi)

                    // Horizon‑biased y.
                    let y = biasedY(rand(&s), minY: minY, k: 3.2)
                    let cx = sqrtf(max(0, 1 - y*y))
                    var d = simd_normalize(simd_float3(sinf(az) * cx, y, cosf(az) * cx))

                    // Intersection distance on the plane (y = height).
                    let t = height / max(0.001, d.y)
                    if !t.isFinite || t <= 0 { continue }
                    let dist = min(t, farCap)

                    // Distance acceptance: prefer the far.
                    let accept = acceptProbability(distance: dist, height: height, farCap: farCap)
                    if rand(&s) > accept { continue }

                    // Variable Poisson spacing check.
                    let cosThresh = minSepCos(forY: y, minY: minY)
                    var ok = true
                    for c in rays where simd_dot(c, d) > cosThresh { ok = false; break }
                    if !ok { continue }

                    rays.append(d)
                }

                // Build clusters at the plane intersections.
                var clusters: [Cluster] = []
                clusters.reserveCapacity(rays.count)

                for d in rays {
                    let y = max(minY, d.y)
                    let t = height / y
                    if !t.isFinite || t <= 0 || t > farCap { continue }

                    let anchor = d * t
                    let dist = length(anchor)

                    // Slight fade very near the far cap.
                    let farFade: Float = dist > (0.94 * farCap)
                        ? max(0.2, 1 - (dist - 0.94 * farCap) / (0.06 * farCap))
                        : 1

                    // Base cluster scale (metres). Varies gently with distance so far clusters
                    // are a touch larger to keep perceived size from shrinking too much.
                    let base = (520.0 + 380.0 * rand(&s)) * (0.92 + 0.18 * saturate((dist - height) / (farCap - height)))
                    let thickness: Float = 260.0 + 220.0 * rand(&s)

                    var puffs: [PuffSpec] = []

                    // ---- LAYER 1: Flat-ish base (wide) ----
                    let baseLift: Float = 30.0
                    let baseCount = 5 + Int(rand(&s) * 3.9) // 5..8
                    for _ in 0..<baseCount {
                        let ox = (rand(&s) - 0.5) * base * 1.6
                        let oz = (rand(&s) - 0.5) * base * 1.1
                        let oy = -thickness * 0.18 + rand(&s) * (thickness * 0.36)
                        let size = base * (0.72 + rand(&s) * 0.48)
                        puffs.append(PuffSpec(
                            pos: anchor + simd_float3(ox, baseLift + oy, oz),
                            size: size,
                            roll: rand(&s) * .pi * 2,
                            atlasIndex: Int(rand(&s) * 4),
                            opacity: farFade * (0.84 + rand(&s) * 0.16)
                        ))
                    }

                    // ---- LAYER 2: Middle fill (keystone) ----
                    let midCount = 4 + Int(rand(&s) * 4.9) // 4..8
                    for _ in 0..<midCount {
                        let ox = (rand(&s) - 0.5) * base * 1.2
                        let oz = (rand(&s) - 0.5) * base * 1.0
                        let oy = 0 + rand(&s) * (thickness * 0.62)
                        let size = base * (0.52 + rand(&s) * 0.42)
                        puffs.append(PuffSpec(
                            pos: anchor + simd_float3(ox, baseLift + oy, oz),
                            size: size,
                            roll: rand(&s) * .pi * 2,
                            atlasIndex: Int(rand(&s) * 4),
                            opacity: farFade
                        ))
                    }

                    // ---- LAYER 3: Cap (small topping puffs) ----
                    let capCount = 3 + Int(rand(&s) * 2.9) // 3..5
                    for _ in 0..<capCount {
                        let ox = (rand(&s) - 0.5) * base * 0.8
                        let oz = (rand(&s) - 0.5) * base * 0.7
                        let oy = thickness * 0.58 + rand(&s) * (thickness * 0.52)
                        let size = base * (0.36 + rand(&s) * 0.33)
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
                minY: max(0.02, minAltitudeY),   // allow very low y for distant horizon
                height: layerHeight,
                farCap: farCap,
                seed: seed &+ 17
            )

            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed &+ 33, count: 4)
            let node = await buildLayerNode(specs: layout, atlas: atlas)
            await completion(node)
        }
    }

    // MARK: SceneKit node assembly

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
            m.diffuse.contents = img            // premultiplied‑alpha image
            m.transparencyMode = .aOne
            m.blendMode = .alpha
            m.transparent.contents = nil        // no double mask

            m.readsFromDepthBuffer = true       // horizon occludes
            m.writesToDepthBuffer = false

            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.diffuse.mipFilter = .linear
            m.diffuse.minificationFilter = .linear
            m.diffuse.magnificationFilter = .linear

            m.isDoubleSided = false
            m.shaderModifiers = [.fragment: fragment]
            materials.append(m)
        }

        // Angle‑safe UV inset for a given rotation (no clamp cropping).
        @inline(__always)
        func insetForAngle(_ a: Float) -> Float {
            let denom = max(1.0, abs(cos(a)) + abs(sin(a))) // 1 .. √2
            let s = 0.98 / denom                            // ~0.98 .. 0.693
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
                let inset = insetForAngle(p.roll)
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
