//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//  Fewer, bigger clusters; all SceneKit/placement on the main actor.
//  Async atlas build is wrapped in a main-actor Task so `await` is legal.
//

import SceneKit
import UIKit
import simd

@MainActor
enum CloudBillboardLayer {

    /// Builds the cloud billboard layer and returns it via `completion` on the main actor.
    static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,
        clusterCount: Int = 56,          // keep to dozens, not hundreds
        seed: UInt32 = 0xC10D5,
        completion: @escaping (SCNNode) -> Void
    ) {
        let layerY: Float = max(1100, min(Float(radius) * 0.34, 1800))

        // Radial bands (XZ around the camera). Far belt is widest/densest.
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        let rNearHole: Float = rNearMax * 0.34

        let rBridge0: Float = rNearMax * 1.06
        let rBridge1: Float = rBridge0 + max(900, Float(radius) * 0.42)

        let rMid0:   Float = rBridge1 - 100
        let rMid1:   Float = rMid0 + max(2100, Float(radius) * 1.05)

        let rFar0:   Float = rMid1 + max(650,  Float(radius) * 0.34)
        let rFar1:   Float = rFar0 + max(3000, Float(radius) * 1.40)

        let rUltra0: Float = rFar1 + max(700,  Float(radius) * 0.40)
        let rUltra1: Float = rUltra0 + max(1600, Float(radius) * 0.60)

        // Allocation per band (dozens total).
        let N = max(24, clusterCount)
        let nearC   = max(2,  Int(Float(N) * 0.06))   // ~6%
        let bridgeC = max(4,  Int(Float(N) * 0.12))   // ~12%
        let midC    = max(12, Int(Float(N) * 0.30))   // ~30%
        let farC    = max(18, Int(Float(N) * 0.42))   // ~42%
        let ultraC  = max(2,  N - nearC - bridgeC - midC - farC)

        var s = (seed == 0) ? 1 : seed
        let bandSpan = (rNearHole, rUltra1)

        // Blue-noise placements with big separations → distinct big clouds.
        // (These helpers are @MainActor in your project; we stay on the main actor here.)
        let nearPts   = CloudBillboardPlacement.poissonAnnulus(
            nearC, r0: rNearHole, r1: rNearMax,
            minSepNear: 1100, minSepFar: 1400, seed: &s)

        let bridgePts = CloudBillboardPlacement.poissonAnnulus(
            bridgeC, r0: rBridge0, r1: rBridge1,
            minSepNear: 900, minSepFar: 1200, seed: &s)

        let midPts    = CloudBillboardPlacement.poissonAnnulus(
            midC, r0: rMid0, r1: rMid1,
            minSepNear: 750, minSepFar: 1050, seed: &s)

        let farPts    = CloudBillboardPlacement.poissonAnnulus(
            farC, r0: rFar0, r1: rFar1,
            minSepNear: 600, minSepFar: 900, seed: &s)

        let ultraPts  = CloudBillboardPlacement.poissonAnnulus(
            ultraC, r0: rUltra0, r1: rUltra1,
            minSepNear: 520, minSepFar: 800, seed: &s)

        var specs: [CloudClusterSpec] = []
        specs.reserveCapacity(N)

        // Bigger clusters across bands so each reads as a “big cloud”.
        for p in nearPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.10, opacityMul: 0.95, tint: nil, seed: &s))
        }
        for p in bridgePts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.05, opacityMul: 0.94, tint: simd_float3(0.98, 0.99, 1.00), seed: &s))
        }
        for p in midPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.02, opacityMul: 0.94, tint: simd_float3(0.97, 0.99, 1.00), seed: &s))
        }
        for p in farPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 0.98, opacityMul: 0.93, tint: simd_float3(0.95, 0.98, 1.00), seed: &s))
        }
        for p in ultraPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 0.86, opacityMul: 0.82, tint: simd_float3(0.90, 0.93, 1.00), seed: &s))
        }

        // Build atlas (async in your project) and the node on the main actor.
        Task { @MainActor in
            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed, count: 6)
            let node  = CloudBillboardFactory.makeNode(from: specs, atlas: atlas)
            completion(node)
        }
    }
}
