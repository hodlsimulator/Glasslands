//
//  CloudBillboardLayer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Billboarded cumulus built from soft sprites.
//  Denser distribution than the “fewer, bigger clusters” variant,
//  with a runtime coverage knob (UserDefaults "clouds.coverage").
//

import SceneKit
import UIKit
import simd

@MainActor
enum CloudBillboardLayer {

    /// Builds the cloud billboard layer and returns it via `completion` on the main actor.
    ///
    /// - Parameters:
    ///   - radius:        sky dome radius
    ///   - minAltitudeY:  normalized [0,1] altitude for the cloud belt center
    ///   - clusterCount:  baseline number of clusters (scaled by coverage)
    ///   - seed:          RNG seed
    ///   - completion:    callback on main actor
    ///
    /// Notes:
    /// - We keep the node name "CumulusBillboardLayer" for compatibility with zenith guards.
    /// - Density can be tuned at runtime by setting:
    ///       UserDefaults.standard.set(1.35 as Float, forKey: "clouds.coverage")
    ///   Valid range is ~[0.75, 1.75]. Defaults to 1.35 if not present.
    static func makeAsync(
        radius: CGFloat,
        minAltitudeY: Float = 0.12,
        clusterCount: Int = 92,     // ↑ from 56 → denser baseline
        seed: UInt32 = 0xC10D5,
        completion: @escaping (SCNNode) -> Void
    ) {
        // --- Coverage & spacing scaling -------------------------------------
        let coverageFromDefaults: Float = {
            if let v = UserDefaults.standard.object(forKey: "clouds.coverage") as? Float { return v }
            return 1.35 // default to a visibly denser sky than the sparse build
        }()
        // Clamp to a sane range so we don't explode draw calls accidentally.
        let coverage: Float = max(0.75, min(coverageFromDefaults, 1.75))
        // Reduce minimum separations roughly with sqrt law to avoid sudden overdraw spikes.
        let sepScale: Float = 1.0 / sqrt(coverage)
        // Scale the cluster budget by coverage.
        let N: Int = max(24, Int((Float(clusterCount) * coverage).rounded()))

        // --- Vertical placement ----------------------------------------------
        let layerY: Float = max(1100, min(Float(radius) * 0.34, 1800))

        // --- Radial bands (XZ around the camera). Far belt is widest/densest. -
        let rNearMax: Float = max(560, Float(radius) * 0.22)
        let rNearHole: Float = rNearMax * 0.26 // ↓ from 0.34 → fills more overhead
        let rBridge0: Float = rNearMax * 1.06
        let rBridge1: Float = rBridge0 + max(900,  Float(radius) * 0.42)
        let rMid0:    Float = rBridge1 - 100
        let rMid1:    Float = rMid0   + max(2100, Float(radius) * 1.05)
        let rFar0:    Float = rMid1   + max(650,  Float(radius) * 0.34)
        let rFar1:    Float = rFar0   + max(3000, Float(radius) * 1.40)
        let rUltra0:  Float = rFar1   + max(700,  Float(radius) * 0.40)
        let rUltra1:  Float = rUltra0 + max(1600, Float(radius) * 0.60)

        // --- Allocation per band (dozens total) ------------------------------
        // Bias a little more into near/bridge to make the sky feel richer around/overhead.
        let nearC   = max( 3, Int(Float(N) * 0.08)) // ~8%
        let bridgeC = max( 6, Int(Float(N) * 0.14)) // ~14%
        let midC    = max(12, Int(Float(N) * 0.32)) // ~32%
        let farC    = max(12, Int(Float(N) * 0.36)) // ~36%
        let ultraC  = max( 2, N - nearC - bridgeC - midC - farC)

        var s = (seed == 0) ? 1 : seed
        let bandSpan: (Float, Float) = (rNearHole, rUltra1)

        // --- Blue-noise placements with tighter separations ------------------
        @inline(__always)
        func scaled(_ a: Float) -> Float { max(200.0, a * sepScale) }

        let nearPts = CloudBillboardPlacement.poissonAnnulus(
            nearC, r0: rNearHole, r1: rNearMax,
            minSepNear: scaled(900.0),  minSepFar: scaled(1250.0), seed: &s)

        let bridgePts = CloudBillboardPlacement.poissonAnnulus(
            bridgeC, r0: rBridge0, r1: rBridge1,
            minSepNear: scaled(800.0),  minSepFar: scaled(1100.0), seed: &s)

        let midPts = CloudBillboardPlacement.poissonAnnulus(
            midC, r0: rMid0, r1: rMid1,
            minSepNear: scaled(650.0),  minSepFar: scaled(900.0),  seed: &s)

        let farPts = CloudBillboardPlacement.poissonAnnulus(
            farC, r0: rFar0, r1: rFar1,
            minSepNear: scaled(520.0),  minSepFar: scaled(760.0),  seed: &s)

        let ultraPts = CloudBillboardPlacement.poissonAnnulus(
            ultraC, r0: rUltra0, r1: rUltra1,
            minSepNear: scaled(440.0),  minSepFar: scaled(680.0),  seed: &s)

        // --- Cluster specs ----------------------------------------------------
        var specs: [CloudClusterSpec] = []
        specs.reserveCapacity(N)

        // Slightly smaller cluster scales than the sparse build, so more can fit
        // without blowing fill-rate; small opacity tweaks to keep depth softness.
        for p in nearPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.06, opacityMul: 0.96, tint: nil, seed: &s))
        }
        for p in bridgePts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.02, opacityMul: 0.95,
                tint: simd_float3(0.98, 0.99, 1.00), seed: &s))
        }
        for p in midPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 1.00, opacityMul: 0.95,
                tint: simd_float3(0.97, 0.99, 1.00), seed: &s))
        }
        for p in farPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 0.96, opacityMul: 0.94,
                tint: simd_float3(0.95, 0.98, 1.00), seed: &s))
        }
        for p in ultraPts {
            specs.append(CloudBillboardPlacement.buildCluster(
                at: p, baseY: layerY, bandSpan: bandSpan,
                scaleMul: 0.86, opacityMul: 0.84,
                tint: simd_float3(0.90, 0.93, 1.00), seed: &s))
        }

        // --- Build atlas (async) and node ------------------------------------
        Task { @MainActor in
            let atlas = await CloudSpriteTexture.makeAtlas(size: 512, seed: seed, count: 8)
            let node  = CloudBillboardFactory.makeNode(from: specs, atlas: atlas)
            node.name = "CumulusBillboardLayer" // keep stable for zenith guards
            completion(node)
        }
    }
}
