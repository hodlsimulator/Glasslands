//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//
//  Distribution:
//  • Near disk (overhead fill, sparse).
//  • Bridge annulus (fills the previous gap).
//  • Mid annulus (main body).
//  • Far annulus (more density than before).
//  • Ultra-far annulus (hugs the horizon).
//
//  Rendering:
//  • Parent node billboards; child plane rotates around Z for roll.
//  • Premultiplied alpha; depth writes disabled; clamp sampling.
//  • Sprites have a hard transparent frame (see CloudSpriteTexture).
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

    // MARK: Build

    nonisolated static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,   // kept for API compatibility (unused in planar bands)
        clusterCount: Int = 120,
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        let layerY: Float = max(1100, min(Float(radius) * 0.34, 1800))

        // -------- Radial bands (XZ around the camera) --------
        let rNearDisk: Float = max(520,  Float(radius) * 0.22)    // overhead fill (sparse)
        let rBridge0:  Float = rNearDisk * 1.08
        let rBridge1:  Float = rNearDisk + max(900, Float(radius) * 0.45)

        let rMid0:     Float = rBridge1 - 120                      // small overlap with bridge ⇒ no gap
        let rMid1:     Float = rMid0 + max(2300, Float(radius) * 1.20)

        let rFar0:     Float = rMid1 + max(800,  Float(radius) * 0.36)
        let rFar1:     Float = rFar0 + max(2400, Float(radius) * 1.05)

        let rUltra0:   Float = rFar1 + max(900,  Float(radius) * 0.40)
        let rUltra1:   Float = rUltra0 + max(1600, Float(radius) * 0.60)  // hugs the horizon

        // -------- Allocation (fewer overhead, more distant) --------
        let N = max(20, clusterCount)
        let nearC   = max(6,  Int(Float(N) * 0.08))   // ~8%
        let bridgeC = max(10, Int(Float(N) * 0.12))   // ~12%
        let midC    = max(28, Int(Float(N) * 0.44))   // ~44% (main body)
        let farC    = max(16, Int(Float(N) * 0.26))   // ~26%
        let ultraC  = max(6,  N - nearC - bridgeC - midC - farC) // ~10%

        Task.detached(priority: .userInitiated) {

            // RNG + helpers
            @inline(__always) func rand(_ s: inout UInt32) -> Float {
                s = 1_664_525 &* s &+ 1_013_904_223
                return Float(s >> 8) * (1.0 / 16_777_216.0)
            }
            @inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
            @inline(__always) func sat(_ x: Float) -> Float { max(0, min(1, x)) }

            var s = seed == 0 ? 1 : seed

            // Poisson in disk
            func poissonDisk(_ n: Int, R: Float, minSepNear: Float, minSepFar: Float, seed: inout UInt32) -> [simd_float2] {
                var pts: [simd_float2] = []
                pts.reserveCapacity(n)
                let maxTries = n * 2600
                var tries = 0
                while pts.count < n && tries < maxTries {
                    tries += 1
                    let t = rand(&seed)
                    let r = sqrt(t) * R
                    let a = rand(&seed) * (.pi * 2)
                    let p = simd_float2(cosf(a) * r, sinf(a) * r)

                    let sep = lerp(minSepNear, minSepFar, r / R)
                    var ok = true
                    for q in pts where distance(p, q) < sep { ok = false; break }
                    if ok { pts.append(p) }
                }
                return pts
            }

            // Poisson in annulus
            func poissonAnnulus(_ n: Int, r0: Float, r1: Float, minSepNear: Float, minSepFar: Float, seed: inout UInt32) -> [simd_float2] {
                var pts: [simd_float2] = []
                pts.reserveCapacity(n)
                let maxTries = n * 3200
                var tries = 0
                while pts.count < n && tries < maxTries {
                    tries += 1
                    let t  = rand(&seed)
                    let r  = sqrt(lerp(r0*r0, r1*r1, t))
                    let a  = rand(&seed) * (.pi * 2)
                    let p  = simd_float2(cosf(a) * r, sinf(a) * r)

                    let tr = sat((r - r0) / (r1 - r0))
                    let sep = lerp(minSepNear, minSepFar, powf(tr, 0.8))
                    var ok = true
                    for q in pts where distance(p, q) < sep { ok = false; break }
                    if ok { pts.append(p) }
                }
                return pts
            }

            // Build one cluster worth of puffs (scale/opacity multipliers per band).
            func buildCluster(at anchorXZ: simd_float2,
                              baseY: Float,
                              dist: Float,
                              scaleMul: Float,
                              opacityMul: Float,
                              seed: inout UInt32) -> Cluster
            {
                // Map to 0..1 over the whole span to stabilise scaling.
                let lo: Float = rNearDisk
                let hi: Float = rUltra1
                let tR = sat((dist - lo) / (hi - lo))

                // Slightly increase world size with distance, then apply band multiplier.
                let scale = (0.92 + 0.28 * tR) * scaleMul

                // Footprint and thickness
                let base = (560.0 + 420.0 * rand(&seed)) * scale
                let thickness: Float = (300.0 + 240.0 * rand(&seed)) * scale
                let baseLift: Float = 30.0 + (rand(&seed) - 0.5) * 20.0

                var puffs: [PuffSpec] = []

                // Base layer (3–4 when close, 4–5 when far)
                let baseCount = (tR < 0.25) ? (3 + Int(rand(&seed) * 1.5))
                                            : (4 + Int(rand(&seed) * 1.5))
                for _ in 0..<baseCount {
                    let ang = (rand(&seed) - 0.5) * (.pi * 1.00)
                    let rx  = base * (0.40 + 0.75 * rand(&seed))
                    let rz  = base * (0.28 + 0.55 * rand(&seed))
                    let off = simd_float3(cosf(ang) * rx, 0, sinf(ang) * rz)

                    let yJit: Float = (rand(&seed) - 0.5) * 110.0
                    let pos  = simd_float3(anchorXZ.x, baseY + yJit, anchorXZ.y) + off + simd_float3(0, baseLift, 0)
                    let size = (270.0 + 240.0 * rand(&seed)) * (0.88 + 0.30 * rand(&seed)) * scale
                    let roll = (rand(&seed) - 0.5) * (.pi * 2)

                    puffs.append(PuffSpec(
                        pos: pos,
                        size: size,
                        roll: roll,
                        atlasIndex: Int(rand(&seed) * 32.0),
                        opacity: (0.78 + 0.20 * tR) * opacityMul
                    ))
                }

                // Cap layer (2–4)
                let capCount = 2 + Int(rand(&seed) * 2.5)
                for _ in 0..<capCount {
                    let ang = (rand(&seed) - 0.5) * (.pi * 0.9)
                    let rx  = base * (0.18 + 0.45 * rand(&seed))
                    let rz  = base * (0.18 + 0.45 * rand(&seed))
                    let off = simd_float3(cosf(ang) * rx, 0, sinf(ang) * rz)

                    let pos  = simd_float3(anchorXZ.x, baseY, anchorXZ.y) + off + simd_float3(0, baseLift + 0.55 * thickness, 0)
                    let size = (180.0 + 180.0 * rand(&seed)) * (0.86 + 0.28 * rand(&seed)) * scale
                    let roll = (rand(&seed) - 0.5) * (.pi * 2)

                    puffs.append(PuffSpec(
                        pos: pos,
                        size: size,
                        roll: roll,
                        atlasIndex: Int(rand(&seed) * 32.0),
                        opacity: (0.74 + 0.18 * tR) * opacityMul
                    ))
                }

                // Optional skirt (adds width)
                if rand(&seed) > 0.58 {
                    let skirtCount = 1 + Int(rand(&seed) * 2.0)
                    for _ in 0..<skirtCount {
                        let ang = (rand(&seed) - 0.5) * (.pi * 1.2)
                        let rx  = base * (0.60 + 0.95 * rand(&seed))
                        let rz  = base * (0.35 + 0.70 * rand(&seed))
                        let off = simd_float3(cosf(ang) * rx, 0, sinf(ang) * rz)

                        let pos  = simd_float3(anchorXZ.x, baseY, anchorXZ.y) + off
                        let size = (210.0 + 220.0 * rand(&seed)) * (0.80 + 0.25 * rand(&seed)) * scale
                        let roll = (rand(&seed) - 0.5) * (.pi * 2)

                        puffs.append(PuffSpec(
                            pos: pos,
                            size: size,
                            roll: roll,
                            atlasIndex: Int(rand(&seed) * 32.0),
                            opacity: (0.68 + 0.16 * tR) * opacityMul
                        ))
                    }
                }

                return Cluster(puffs: puffs)
            }

            // ---- Anchors per band ----
            let nearAnch = poissonDisk(nearC, R: rNearDisk,
                                       minSepNear: 360, minSepFar: 480, seed: &s)

            let bridgeAnch = poissonAnnulus(bridgeC, r0: rBridge0, r1: rBridge1,
                                            minSepNear: 360, minSepFar: 640, seed: &s)

            let midAnch = poissonAnnulus(midC, r0: rMid0, r1: rMid1,
                                         minSepNear: 420, minSepFar: 820, seed: &s)

            let farAnch = poissonAnnulus(farC, r0: rFar0, r1: rFar1,
                                         minSepNear: 640, minSepFar: 980, seed: &s)

            let ultraAnch = poissonAnnulus(ultraC, r0: rUltra0, r1: rUltra1,
                                           minSepNear: 840, minSepFar: 1240, seed: &s)

            // ---- Build clusters ----
            var clusters: [Cluster] = []
            clusters.reserveCapacity(nearAnch.count + bridgeAnch.count + midAnch.count + farAnch.count + ultraAnch.count)

            for a in nearAnch   { clusters.append(buildCluster(at: a, baseY: layerY, dist: length(a), scaleMul: 0.78, opacityMul: 0.92, seed: &s)) }
            for a in bridgeAnch { clusters.append(buildCluster(at: a, baseY: layerY, dist: length(a), scaleMul: 0.90, opacityMul: 0.96, seed: &s)) }
            for a in midAnch    { clusters.append(buildCluster(at: a, baseY: layerY, dist: length(a), scaleMul: 1.00, opacityMul: 1.00, seed: &s)) }
            for a in farAnch    { clusters.append(buildCluster(at: a, baseY: layerY, dist: length(a), scaleMul: 1.08, opacityMul: 0.96, seed: &s)) }
            for a in ultraAnch  { clusters.append(buildCluster(at: a, baseY: layerY, dist: length(a), scaleMul: 0.88, opacityMul: 0.90, seed: &s)) } // small, horizon-hugging

            // Texture atlas
            let atlas = await CloudSpriteTexture.makeAtlas(size: 512,
                                                           seed: seed ^ 0x5A5A_0314,
                                                           count: 4)

            await MainActor.run {
                let node = buildNodes(specs: clusters, atlas: atlas)
                completion(node)
            }
        }
    }

    // MARK: SceneKit assembly

    @MainActor
    private static func buildNodes(specs: [Cluster], atlas: CloudSpriteTexture.Atlas) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        // Trim ultra-low alphas early to avoid far-mip fogging.
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

        // Clamp sampling; sprites have a hard transparent frame.
        template.diffuse.wrapS = .clamp
        template.diffuse.wrapT = .clamp
        template.diffuse.mipFilter = .linear
        template.diffuse.minificationFilter = .linear
        template.diffuse.magnificationFilter = .linear
        template.diffuse.maxAnisotropy = 4.0

        for cl in specs {
            let group = SCNNode()

            for p in cl.puffs {
                // Parent that faces the camera…
                let bb = SCNNode()
                bb.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)
                let b = SCNBillboardConstraint()
                b.freeAxes = .all
                bb.constraints = [b]

                // …child plane rotated around Z for roll.
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
