//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Billboarded cumulus built from soft sprites.
//  Updated: multi-band placement (near → horizon) for better distribution.
//

import SceneKit
import simd
import UIKit

struct CloudBillboardLayer {

    struct Params {
        var radius: CGFloat
        var clusterCount: Int
        var seed: UInt32
        var minAltitudeY: Float
    }

    // Build a node containing cluster groups (each group contains multiple puff planes).
    // Async is used for texture generation and node creation to keep main thread light.
    static func makeAsync(
        radius: CGFloat,
        clusterCount: Int = 92,
        seed: UInt32 = 1,
        minAltitudeY: Float = 0.12
    ) async -> SCNNode {

        // Sprite atlas is still generated for future/compat use (factory is volumetric currently).
        let atlas = await CloudSpriteTexture.makeAtlas(size: 512, count: 8)

        let p = Params(
            radius: radius,
            clusterCount: clusterCount,
            seed: seed,
            minAltitudeY: minAltitudeY
        )

        let root = SCNNode()
        root.name = "CumulusBillboardLayer"

        // Coverage control (default tuned for “mid-day scattered”).
        let coverage: Float = {
            let v = UserDefaults.standard.float(forKey: "clouds.coverage")
            return (v > 0.01) ? v : 1.35
        }()

        // --- Vertical placement ----------------------------------------------
        // A single fixed altitude makes the horizon feel empty. This build
        // intentionally lowers far/horizon bands to create a cloud bank.
        let yNear: Float = max(1100, min(Float(radius) * 0.36, 1800))
        let yMid: Float = max(950,  yNear - 180)
        let yFar: Float = max(820,  yNear - 360)
        let yHzn: Float = max(700,  yNear - 520)

        // --- Radial bands (scaled from radius) -------------------------------
        // Keep the near band fairly tight so the zenith doesn't look empty.
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        // Smaller hole gives coverage closer to the zenith without making
        // the layer feel like a tight ceiling.
        let rNearHole: Float = rNearMax * 0.12

        let rBridge0: Float = rNearMax * 1.03
        let rBridge1: Float = rBridge0 + max(900, Float(radius) * 0.46)

        let rMid0: Float = rBridge1 - 120
        let rMid1: Float = rMid0 + max(2400, Float(radius) * 1.15)

        let rFar0: Float = rMid1 + max(700, Float(radius) * 0.40)
        let rFar1: Float = rFar0 + max(3400, Float(radius) * 1.55)

        // Horizon band: sits near the far clip, lower altitude, larger scale.
        let rHzn0: Float = rFar1 + max(850, Float(radius) * 0.45)
        let rHzn1Wanted: Float = rHzn0 + max(2400, Float(radius) * 0.75)

        // Clamp horizon distance to avoid camera zFar clipping (engine uses ~20k).
        let approxZFar: Float = 20_000
        let rHzn1Limit: Float = max(rHzn0 + 1600, approxZFar - 800)
        let rHzn1: Float = min(rHzn1Wanted, rHzn1Limit)

        let bandSpan: (Float, Float) = (rNearHole, rHzn1)

        // Cluster budget (biased towards far/horizon so the horizon isn't empty).
        let N = max(1, Int(Float(p.clusterCount) * coverage))

        let nearC = max(3, Int(Float(N) * 0.07))
        let brdgC = max(6, Int(Float(N) * 0.13))
        let midC  = max(10, Int(Float(N) * 0.30))
        let farC  = max(10, Int(Float(N) * 0.32))
        let hznC  = max(2, N - nearC - brdgC - midC - farC)

        // Place clusters with blue-noise distribution per band.
        var rng = p.seed

        let nearPts = CloudBillboardPlacement.poissonAnnulus(
            count: nearC,
            r0: rNearHole,
            r1: rNearMax,
            minSepNear: 520,
            minSepFar: 820,
            seed: &rng
        )

        let brdgPts = CloudBillboardPlacement.poissonAnnulus(
            count: brdgC,
            r0: rBridge0,
            r1: rBridge1,
            minSepNear: 600,
            minSepFar: 980,
            seed: &rng
        )

        let midPts = CloudBillboardPlacement.poissonAnnulus(
            count: midC,
            r0: rMid0,
            r1: rMid1,
            minSepNear: 720,
            minSepFar: 1280,
            seed: &rng
        )

        let farPts = CloudBillboardPlacement.poissonAnnulus(
            count: farC,
            r0: rFar0,
            r1: rFar1,
            minSepNear: 900,
            minSepFar: 1500,
            seed: &rng
        )

        let hznPts = CloudBillboardPlacement.poissonAnnulus(
            count: hznC,
            r0: rHzn0,
            r1: rHzn1,
            minSepNear: 720,
            minSepFar: 1100,
            seed: &rng
        )

        let factory = CloudBillboardFactory.initWithAtlas(atlas.images.first)

        func addBand(
            points: [simd_float2],
            baseY: Float,
            scaleMul: Float,
            opacityMul: Float,
            tint: simd_float3
        ) {
            for p2 in points {
                var s = rng
                let spec = CloudBillboardPlacement.buildCluster(
                    at: p2,
                    baseY: baseY,
                    bandSpan: bandSpan,
                    scaleMul: scaleMul,
                    opacityMul: opacityMul,
                    tint: tint,
                    seed: &s
                )
                rng &+= 0x9E3779B9 // stir RNG between clusters
                let node = factory.makeNode(from: spec)
                root.addChildNode(node)
            }
        }

        // Band tints (subtle atmospheric perspective).
        let tintNear = simd_float3(1.00, 1.00, 1.00)
        let tintMid  = simd_float3(0.98, 0.99, 1.00)
        let tintFar  = simd_float3(0.94, 0.97, 1.00)
        let tintHzn  = simd_float3(0.90, 0.95, 1.00)

        // Near: big, bright, overhead volume.
        addBand(points: nearPts, baseY: yNear, scaleMul: 1.06, opacityMul: 0.96, tint: tintNear)

        // Bridge: transition.
        addBand(points: brdgPts, baseY: yMid, scaleMul: 1.02, opacityMul: 0.95, tint: tintMid)

        // Mid: bulk of the field.
        addBand(points: midPts, baseY: yMid, scaleMul: 1.00, opacityMul: 0.94, tint: tintMid)

        // Far: slightly larger to remain legible, lower altitude.
        addBand(points: farPts, baseY: yFar, scaleMul: 1.12, opacityMul: 0.90, tint: tintFar)

        // Horizon: larger + softer bank.
        addBand(points: hznPts, baseY: yHzn, scaleMul: 1.34, opacityMul: 0.78, tint: tintHzn)

        return root
    }
}
