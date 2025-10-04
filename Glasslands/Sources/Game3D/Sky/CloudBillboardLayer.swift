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

        // Multi-annulus distribution with a zenith hole.
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        let rNearHole: Float = rNearMax * 0.34
        let rBridge0: Float = rNearMax * 1.06
        let rBridge1: Float = rBridge0 + max(900,  Float(radius) * 0.42)
        let rMid0: Float    = rBridge1 - 100
        let rMid1: Float    = rMid0 + max(2100, Float(radius) * 1.05)
        let rFar0: Float    = rMid1 + max(650,  Float(radius) * 0.34)
        let rFar1: Float    = rFar0 + max(3000, Float(radius) * 1.40)
        let rUltra0: Float  = rFar1 + max(700,  Float(radius) * 0.40)
        let rUltra1: Float  = rUltra0 + max(1600, Float(radius) * 0.60)

        let N = max(30, clusterCount)
        let nearC   = max(2,  Int(Float(N) * 0.04))
        let bridgeC = max(6,  Int(Float(N) * 0.10))
        let midC    = max(24, Int(Float(N) * 0.30))
        let farC    = max(36, Int(Float(N) * 0.44))
        let ultraC  = max(6,  N - nearC - bridgeC - midC - farC)

        Task.detached(priority: .userInitiated) {
            var s = (seed == 0) ? 1 : seed

            // Pure math (global free functions), safe off-main:
            let nearPts   = cbpPoissonAnnulus(nearC,   r0: rNearHole, r1: rNearMax, minSepNear: 820, minSepFar: 980, seed: &s)
            let bridgePts = cbpPoissonAnnulus(bridgeC, r0: rBridge0,  r1: rBridge1,  minSepNear: 620, minSepFar: 780, seed: &s)
            let midPts    = cbpPoissonAnnulus(midC,    r0: rMid0,     r1: rMid1,     minSepNear: 520, minSepFar: 700, seed: &s)
            let farPts    = cbpPoissonAnnulus(farC,    r0: rFar0,     r1: rFar1,     minSepNear: 380, minSepFar: 560, seed: &s)
            let ultraPts  = cbpPoissonAnnulus(ultraC,  r0: rUltra0,   r1: rUltra1,   minSepNear: 360, minSepFar: 520, seed: &s)

            var specs: [CloudClusterSpec] = []
            specs.reserveCapacity(N)
            let bandSpan = (rNearHole, rUltra1)

            for p in nearPts {
                specs.append(cbpBuildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                            scaleMul: 0.90, opacityMul: 0.88, tint: nil, seed: &s))
            }
            for p in bridgePts {
                specs.append(cbpBuildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                            scaleMul: 0.98, opacityMul: 0.93,
                                            tint: simd_float3(0.98, 0.99, 1.00), seed: &s))
            }
            for p in midPts {
                specs.append(cbpBuildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                            scaleMul: 1.00, opacityMul: 0.94,
                                            tint: simd_float3(0.97, 0.99, 1.00), seed: &s))
            }
            for p in farPts {
                specs.append(cbpBuildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
                                            scaleMul: 0.88, opacityMul: 0.92,
                                            tint: simd_float3(0.95, 0.98, 1.00), seed: &s))
            }
            for p in ultraPts {
                specs.append(cbpBuildCluster(at: p, baseY: layerY, bandSpan: bandSpan,
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
