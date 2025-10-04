//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//
//  Distribution:
//  • Ultra-far annulus: thin, hazy line at the horizon.
//  • Far annulus: dense “distance belt” that carries most of the read.
//  • Mid annulus: moderate; bridges to the distance.
//  • Bridge annulus: light; avoids gaps as it approaches overhead.
//  • Near annulus (with zenith hole): only a few directly overhead.
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
    static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,
        clusterCount: Int = 140,
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        let layerY: Float = max(1100, min(Float(radius) * 0.34, 1800))

        // Multi-annulus distribution with a zenith hole (restores d99043f feel).
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        let rNearHole: Float = rNearMax * 0.34
        let rBridge0: Float = rNearMax * 1.06
        let rBridge1: Float = rBridge0 + max(900,  Float(radius) * 0.42)
        let rMid0:   Float = rBridge1 - 100
        let rMid1:   Float = rMid0    + max(2100, Float(radius) * 1.05)
        let rFar0:   Float = rMid1    + max(650,  Float(radius) * 0.34)
        let rFar1:   Float = rFar0    + max(3000, Float(radius) * 1.40)
        let rUltra0: Float = rFar1    + max(700,  Float(radius) * 0.40)
        let rUltra1: Float = rUltra0  + max(1600, Float(radius) * 0.60)

        let N = max(30, clusterCount)
        let nearC   = max(2,  Int(Float(N) * 0.04))
        let bridgeC = max(6,  Int(Float(N) * 0.10))
        let midC    = max(24, Int(Float(N) * 0.30))
        let farC    = max(36, Int(Float(N) * 0.44))
        let ultraC  = max(6,  N - nearC - bridgeC - midC - farC)

        Task.detached(priority: .userInitiated) {
            // Local pure-math helpers (not actor-isolated)
            @inline(__always) func randf(_ s: inout UInt32) -> Float {
                s = 1_664_525 &* s &+ 1_013_904_223
                return Float(s >> 8) * (1.0 / 16_777_216.0)
            }
            @inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
            @inline(__always) func sat(_ x: Float) -> Float { max(0, min(1, x)) }

            func poissonAnnulus(
                _ n: Int, r0: Float, r1: Float, minSepNear: Float, minSepFar: Float, seed: inout UInt32
            ) -> [simd_float2] {
                var pts: [simd_float2] = []
                pts.reserveCapacity(n)
                let maxTries = max(1, n) * 3200
                var tries = 0
                while pts.count < n && tries < maxTries {
                    tries += 1
                    let t  = randf(&seed)
                    let rr = sqrt(lerp(r0*r0, r1*r1, t))
                    let a  = randf(&seed) * (.pi * 2)
                    let p  = simd_float2(cosf(a) * rr, sinf(a) * rr)
                    let tr  = sat((rr - r0) / max(1, r1 - r0))
                    let sep = lerp(minSepNear, minSepFar, powf(tr, 0.8))
                    var ok = true
                    for q in pts where distance(p, q) < sep { ok = false; break }
                    if ok { pts.append(p) }
                }
                return pts
            }

            func buildCluster(
                at anchorXZ: simd_float2,
                baseY: Float,
                bandSpan: (Float, Float),
                scaleMul: Float,
                opacityMul: Float,
                tint: simd_float3?,
                seed: inout UInt32
            ) -> CloudClusterSpec {
                let (lo, hi) = bandSpan
                let dist = length(anchorXZ)
                let tR = sat((dist - lo) / max(1, hi - lo))  // 0 near → 1 far

                let scale = (1.18 - 0.40 * tR) * scaleMul
                let base = (520.0 + 380.0 * randf(&seed)) * scale
                let thickness: Float = (260.0 + 200.0 * randf(&seed)) * scale
                let baseLift: Float = 24.0 + (randf(&seed) - 0.5) * 16.0

                var puffs: [CloudPuffSpec] = []
                puffs.reserveCapacity(12)

                // Base ring (3–5 large puffs)
                let baseCount = 3 + Int(randf(&seed) * 2.8)
                for _ in 0..<baseCount {
                    let ang = randf(&seed) * (.pi * 2)
                    let rad = 110.0 + randf(&seed) * 90.0
                    let sz  = 420.0 + randf(&seed) * 220.0
                    let x = anchorXZ.x + cosf(ang) * rad
                    let z = anchorXZ.y + sinf(ang) * rad
                    let y = baseY + base + baseLift
                    let op = 0.92 - 0.15 * tR
                    puffs.append(CloudPuffSpec(
                        pos: simd_float3(x, y, z),
                        size: sz,
                        roll: randf(&seed) * .pi,
                        atlasIndex: Int(randf(&seed) * 1000) % 6,
                        opacity: max(0.0, min(1.0, op)) * opacityMul,
                        tint: tint
                    ))
                }

                // Top cap (smaller, lifting the silhouette)
                let capCount = 2 + Int(randf(&seed) * 2.0)
                for _ in 0..<capCount {
                    let ang = randf(&seed) * (.pi * 2)
                    let rad = 60.0 + randf(&seed) * 70.0
                    let sz  = 260.0 + randf(&seed) * 180.0
                    let x = anchorXZ.x + cosf(ang) * rad
                    let z = anchorXZ.y + sinf(ang) * rad
                    let y = baseY + base + thickness
                    let op = 0.86 - 0.18 * tR
                    puffs.append(CloudPuffSpec(
                        pos: simd_float3(x, y, z),
                        size: sz,
                        roll: randf(&seed) * .pi,
                        atlasIndex: Int(randf(&seed) * 1000) % 6,
                        opacity: max(0.0, min(1.0, op)) * opacityMul,
                        tint: tint
                    ))
                }

                return CloudClusterSpec(puffs: puffs)
            }

            var s = (seed == 0) ? 1 : seed
            let nearPts   = poissonAnnulus(nearC,   r0: rNearHole, r1: rNearMax, minSepNear: 820, minSepFar: 980, seed: &s)
            let bridgePts = poissonAnnulus(bridgeC, r0: rBridge0,  r1: rBridge1,  minSepNear: 620, minSepFar: 780, seed: &s)
            let midPts    = poissonAnnulus(midC,    r0: rMid0,     r1: rMid1,     minSepNear: 520, minSepFar: 700, seed: &s)
            let farPts    = poissonAnnulus(farC,    r0: rFar0,     r1: rFar1,     minSepNear: 380, minSepFar: 560, seed: &s)
            let ultraPts  = poissonAnnulus(ultraC,  r0: rUltra0,   r1: rUltra1,   minSepNear: 360, minSepFar: 520, seed: &s)

            var specs: [CloudClusterSpec] = []
            specs.reserveCapacity(N)
            let bandSpan = (rNearHole, rUltra1)

            for p in nearPts {
                specs.append(buildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                          scaleMul: 0.90, opacityMul: 0.88, tint: nil, seed: &s))
            }
            for p in bridgePts {
                specs.append(buildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                          scaleMul: 0.98, opacityMul: 0.93,
                                          tint: simd_float3(0.98, 0.99, 1.00), seed: &s))
            }
            for p in midPts {
                specs.append(buildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                          scaleMul: 1.00, opacityMul: 0.94,
                                          tint: simd_float3(0.97, 0.99, 1.00), seed: &s))
            }
            for p in farPts {
                specs.append(buildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                          scaleMul: 0.88, opacityMul: 0.92,
                                          tint: simd_float3(0.95, 0.98, 1.00), seed: &s))
            }
            for p in ultraPts {
                specs.append(buildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                          scaleMul: 0.74, opacityMul: 0.78,
                                          tint: simd_float3(0.90, 0.93, 1.00), seed: &s))
            }

            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed, count: 6)

            // Build SceneKit nodes on the main actor.
            let node = await MainActor.run {
                CloudBillboardFactory.makeNode(from: specs, atlas: atlas)
            }
            await completion(node)
        }
    }
}
