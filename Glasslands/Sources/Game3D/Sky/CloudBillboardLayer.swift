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

    /// Async builder. Call from anywhere; completion hops to main for SceneKit.
    static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,
        clusterCount: Int = 120,
        seed: UInt32 = 0xC10D5,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        let layerY: Float = max(1100, min(Float(radius) * 0.34, 1800))

        // Radial bands (XZ around the camera)
        let rNearDisk: Float = max(520,  Float(radius) * 0.22)
        let rBridge0:  Float = rNearDisk * 1.08
        let rBridge1:  Float = rNearDisk + max(900,  Float(radius) * 0.45)
        let rMid0:     Float = rBridge1 - 120
        let rMid1:     Float = rMid0 + max(2300, Float(radius) * 1.20)
        let rFar0:     Float = rMid1 + max(800,  Float(radius) * 0.36)
        let rFar1:     Float = rFar0 + max(2400, Float(radius) * 1.05)
        let rUltra0:   Float = rFar1 + max(900,  Float(radius) * 0.40)
        let rUltra1:   Float = rUltra0 + max(1600, Float(radius) * 0.60)

        // Allocation per band
        let N = max(20, clusterCount)
        let nearC   = max(6,  Int(Float(N) * 0.08))
        let bridgeC = max(10, Int(Float(N) * 0.12))
        let midC    = max(28, Int(Float(N) * 0.44))
        let farC    = max(16, Int(Float(N) * 0.26))
        let ultraC  = max(6,  N - nearC - bridgeC - midC - farC)

        Task.detached(priority: .userInitiated) {
            var s = (seed == 0) ? 1 : seed

            // NOTE: These calls are main-actor isolated by the compiler;
            // hop with `await` to satisfy isolation.
            let nearPts  = await CloudBillboardPlacement.poissonDisk(
                nearC, radius: rNearDisk, minSepNear: 380, minSepFar: 540, seed: &s
            )
            let bridgePts = await CloudBillboardPlacement.poissonAnnulus(
                bridgeC, r0: rBridge0, r1: rBridge1, minSepNear: 520, minSepFar: 700, seed: &s
            )
            let midPts   = await CloudBillboardPlacement.poissonAnnulus(
                midC, r0: rMid0, r1: rMid1, minSepNear: 560, minSepFar: 780, seed: &s
            )
            let farPts   = await CloudBillboardPlacement.poissonAnnulus(
                farC, r0: rFar0, r1: rFar1, minSepNear: 520, minSepFar: 720, seed: &s
            )
            let ultraPts = await CloudBillboardPlacement.poissonAnnulus(
                ultraC, r0: rUltra0, r1: rUltra1, minSepNear: 420, minSepFar: 640, seed: &s
            )

            var specs: [CloudClusterSpec] = []
            specs.reserveCapacity(N)
            let bandSpan = (rNearDisk, rUltra1)

            for p in nearPts {
                specs.append(
                    await CloudBillboardPlacement.buildCluster(
                        at: p, baseY: layerY, bandSpan: bandSpan,
                        scaleMul: 1.20, opacityMul: 0.96, seed: &s
                    )
                )
            }
            for p in bridgePts {
                specs.append(
                    await CloudBillboardPlacement.buildCluster(
                        at: p, baseY: layerY, bandSpan: bandSpan,
                        scaleMul: 1.08, opacityMul: 0.95, seed: &s
                    )
                )
            }
            for p in midPts {
                specs.append(
                    await CloudBillboardPlacement.buildCluster(
                        at: p, baseY: layerY, bandSpan: bandSpan,
                        scaleMul: 1.00, opacityMul: 0.94, seed: &s
                    )
                )
            }
            for p in farPts {
                specs.append(
                    await CloudBillboardPlacement.buildCluster(
                        at: p, baseY: layerY, bandSpan: bandSpan,
                        scaleMul: 0.88, opacityMul: 0.92, seed: &s
                    )
                )
            }
            for p in ultraPts {
                specs.append(
                    await CloudBillboardPlacement.buildCluster(
                        at: p, baseY: layerY, bandSpan: bandSpan,
                        scaleMul: 0.82, opacityMul: 0.90, seed: &s
                    )
                )
            }

            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed, count: 6)
            let node  = await CloudBillboardFactory.makeNode(from: specs, atlas: atlas)
            await completion(node)
        }
    }
}
