//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Billboard cloud cluster builder.
//
//  Key change:
//  - Default build is "shadow proxies" (cluster nodes only, no puff planes).
//    Visual clouds come from VolumetricCloudLayer (single Metal draw).
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

    // Default is shadow proxies.
    // Setting UserDefaults key "clouds.renderPuffs" = true restores the old heavy render path.
    static func makeAsync(
        radius: CGFloat,
        clusterCount: Int = 92,
        seed: UInt32 = 1,
        minAltitudeY: Float = 0.12,
        renderPuffs: Bool = false
    ) async -> SCNNode {

        let wantsPuffs: Bool = {
            if UserDefaults.standard.object(forKey: "clouds.renderPuffs") != nil {
                return UserDefaults.standard.bool(forKey: "clouds.renderPuffs")
            }
            return renderPuffs
        }()

        // Only generate sprite atlases if puff planes are actually being built.
        let atlasImage: UIImage? = {
            guard wantsPuffs else { return nil }
            return nil
        }()

        let atlas: Any? = wantsPuffs ? await CloudSpriteTexture.makeAtlas(size: 512, count: 8) : nil
        let firstAtlasImage: UIImage? = (atlas as? (any _CloudAtlasCarrier))?.images.first
        let factory = CloudBillboardFactory.initWithAtlas(firstAtlasImage ?? atlasImage)

        let p = Params(radius: radius, clusterCount: clusterCount, seed: seed, minAltitudeY: minAltitudeY)

        let root = SCNNode()
        root.name = "CumulusBillboardLayer"

        let coverage: Float = {
            let v = UserDefaults.standard.float(forKey: "clouds.coverage")
            return (v > 0.01) ? v : 1.0
        }()

        // Vertical placement
        let yNear: Float = max(1100, min(Float(radius) * 0.36, 1800))
        let yMid: Float = max(950, yNear - 180)
        let yFar: Float = max(820, yNear - 360)
        let yHzn: Float = max(700, yNear - 520)

        // Radial bands
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        let rNearHole: Float = rNearMax * 0.12
        let rBridge0: Float = rNearMax * 1.03
        let rBridge1: Float = rBridge0 + max(900, Float(radius) * 0.46)
        let rMid0: Float = rBridge1 - 120
        let rMid1: Float = rMid0 + max(2400, Float(radius) * 1.15)
        let rFar0: Float = rMid1 + max(700, Float(radius) * 0.40)
        let rFar1: Float = rFar0 + max(3400, Float(radius) * 1.55)

        let rHzn0: Float = rFar1 + max(850, Float(radius) * 0.45)
        let rHzn1Wanted: Float = rHzn0 + max(2400, Float(radius) * 0.75)
        let approxZFar: Float = 20_000
        let rHzn1Limit: Float = max(rHzn0 + 1600, approxZFar - 800)
        let rHzn1: Float = min(rHzn1Wanted, rHzn1Limit)

        let bandSpan: (Float, Float) = (rNearHole, rHzn1)

        // Cluster budget
        let N = max(1, Int(Float(p.clusterCount) * coverage))
        let nearC = max(4, Int(Float(N) * 0.10))
        let brdgC = max(6, Int(Float(N) * 0.14))
        let midC  = max(10, Int(Float(N) * 0.28))
        let farC  = max(10, Int(Float(N) * 0.31))
        let hznC  = max(2, N - nearC - brdgC - midC - farC)

        var rng = p.seed

        let nearPts = CloudBillboardPlacement.poissonAnnulus(
            count: nearC, r0: rNearHole, r1: rNearMax,
            minSepNear: 520, minSepFar: 820, seed: &rng
        )
        let brdgPts = CloudBillboardPlacement.poissonAnnulus(
            count: brdgC, r0: rBridge0, r1: rBridge1,
            minSepNear: 600, minSepFar: 980, seed: &rng
        )
        let midPts = CloudBillboardPlacement.poissonAnnulus(
            count: midC, r0: rMid0, r1: rMid1,
            minSepNear: 720, minSepFar: 1280, seed: &rng
        )
        let farPts = CloudBillboardPlacement.poissonAnnulus(
            count: farC, r0: rFar0, r1: rFar1,
            minSepNear: 900, minSepFar: 1500, seed: &rng
        )
        let hznPts = CloudBillboardPlacement.poissonAnnulus(
            count: hznC, r0: rHzn0, r1: rHzn1,
            minSepNear: 720, minSepFar: 1100, seed: &rng
        )

        // Band tints (subtle atmospheric perspective).
        let tintNear = simd_float3(1.00, 1.00, 1.00)
        let tintMid  = simd_float3(0.995, 0.997, 1.00)
        let tintFar  = simd_float3(0.985, 0.990, 1.00)
        let tintHzn  = simd_float3(0.970, 0.985, 1.00)

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
                rng &+= 0x9E3779B9

                let node = factory.makeNode(from: spec, renderPuffs: wantsPuffs)
                root.addChildNode(node)
            }
        }

        addBand(points: nearPts, baseY: yNear, scaleMul: 1.06, opacityMul: 0.96, tint: tintNear)
        addBand(points: brdgPts, baseY: yMid,  scaleMul: 1.02, opacityMul: 0.95, tint: tintMid)
        addBand(points: midPts,  baseY: yMid,  scaleMul: 1.00, opacityMul: 0.94, tint: tintMid)
        addBand(points: farPts,  baseY: yFar,  scaleMul: 1.12, opacityMul: 0.92, tint: tintFar)
        addBand(points: hznPts,  baseY: yHzn,  scaleMul: 1.28, opacityMul: 0.82, tint: tintHzn)

        return root
    }
}

// Local protocol purely to avoid hard-coding the CloudSpriteTexture atlas type.
// CloudSpriteTexture.makeAtlas(...) in this project returns an object with `images: [UIImage]`.
private protocol _CloudAtlasCarrier {
    var images: [UIImage] { get }
}
