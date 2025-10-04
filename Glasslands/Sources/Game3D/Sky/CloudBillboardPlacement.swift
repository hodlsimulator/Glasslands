//
//  CloudBillboardPlacement.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Poisson sampling and cauliflower cluster construction.
//

import simd
import Foundation

enum CloudBillboardPlacement {

    // MARK: RNG / helpers

    @inline(__always)
    private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    @inline(__always)
    private static func sat(_ x: Float) -> Float {
        max(0, min(1, x))
    }

    // MARK: Blue-noise-ish placements

    static func poissonDisk(
        _ n: Int,
        radius R: Float,
        minSepNear: Float,
        minSepFar: Float,
        seed: inout UInt32
    ) async -> [simd_float2] {
        var pts: [simd_float2] = []
        pts.reserveCapacity(n)

        let maxTries = n * 2600
        var tries = 0

        while pts.count < n && tries < maxTries {
            tries += 1

            let t = frand(&seed)
            let r = sqrt(t) * R
            let a = frand(&seed) * (.pi * 2)
            let p = simd_float2(cosf(a) * r, sinf(a) * r)

            let sep = lerp(minSepNear, minSepFar, r / R)

            var ok = true
            for q in pts where simd_distance(p, q) < sep { ok = false; break }
            if ok { pts.append(p) }
        }

        return pts
    }

    static func poissonAnnulus(
        _ n: Int,
        r0: Float, r1: Float,
        minSepNear: Float,
        minSepFar: Float,
        seed: inout UInt32
    ) async -> [simd_float2] {
        var pts: [simd_float2] = []
        pts.reserveCapacity(n)

        let maxTries = n * 3200
        var tries = 0

        while pts.count < n && tries < maxTries {
            tries += 1

            let t = frand(&seed)
            let r = sqrt(lerp(r0*r0, r1*r1, t))
            let a = frand(&seed) * (.pi * 2)
            let p = simd_float2(cosf(a) * r, sinf(a) * r)

            let tr = sat((r - r0) / max(1, r1 - r0))
            let sep = lerp(minSepNear, minSepFar, powf(tr, 0.8))

            var ok = true
            for q in pts where simd_distance(p, q) < sep { ok = false; break }
            if ok { pts.append(p) }
        }

        return pts
    }

    // MARK: Cluster construction

    static func buildCluster(
        at anchorXZ: simd_float2,
        baseY: Float,
        bandSpan: (Float, Float),
        scaleMul: Float,
        opacityMul: Float,
        tint: simd_float3? = nil,
        seed: inout UInt32
    ) async -> CloudClusterSpec {
        let (lo, hi) = bandSpan
        let dist = simd_length(anchorXZ)
        let tR = sat((dist - lo) / max(1, hi - lo))        // 0 near → 1 far

        // Farther = slightly smaller, fainter
        let scale = (1.18 - 0.40 * tR) * scaleMul
        let base: Float = (520.0 + 380.0 * frand(&seed)) * scale
        let thickness: Float = (260.0 + 200.0 * frand(&seed)) * scale
        let baseLift: Float = 24.0 + (frand(&seed) - 0.5) * 16.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(12)

        // Base ring (3–5 large puffs)
        let baseCount = 3 + Int(frand(&seed) * 2.8)
        for i in 0..<baseCount {
            let th = Float(i) / max(1, Float(baseCount)) * 2 * .pi + frand(&seed) * 0.4
            let r = base * (0.34 + frand(&seed) * 0.10)
            let px = anchorXZ.x + cosf(th) * r
            let pz = anchorXZ.y + sinf(th) * r
            let py = baseY + baseLift + frand(&seed) * 36.0
            let sz = base * (0.62 + frand(&seed) * 0.22)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(px, py, pz),
                size: sz,
                roll: frand(&seed) * .pi * 2,
                atlasIndex: Int(frand(&seed) * 6.0),
                opacity: (0.90 + 0.08 * frand(&seed)) * opacityMul,
                tint: tint
            ))
        }

        // Crown (2–3 smaller puffs on top)
        let crown = 2 + Int(frand(&seed) * 2.4)
        for _ in 0..<crown {
            let th = frand(&seed) * 2 * .pi
            let r = base * (0.18 + frand(&seed) * 0.16)
            let px = anchorXZ.x + cosf(th) * r
            let pz = anchorXZ.y + sinf(th) * r
            let py = baseY + baseLift + thickness * (0.34 + frand(&seed) * 0.22)
            let sz = base * (0.44 + frand(&seed) * 0.18)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(px, py, pz),
                size: sz,
                roll: frand(&seed) * .pi * 2,
                atlasIndex: Int(frand(&seed) * 6.0),
                opacity: (0.86 + 0.08 * frand(&seed)) * opacityMul,
                tint: tint
            ))
        }

        // Wisps (1–3 tiny connectors)
        let wisps = 1 + Int(frand(&seed) * 2.6)
        for _ in 0..<wisps {
            let th = frand(&seed) * 2 * .pi
            let r = base * (0.36 + frand(&seed) * 0.30)
            let px = anchorXZ.x + cosf(th) * r
            let pz = anchorXZ.y + sinf(th) * r
            let py = baseY + baseLift + thickness * (0.15 + frand(&seed) * 0.25)
            let sz = base * (0.28 + frand(&seed) * 0.12)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(px, py, pz),
                size: sz,
                roll: frand(&seed) * .pi * 2,
                atlasIndex: Int(frand(&seed) * 6.0),
                opacity: (0.80 + 0.08 * frand(&seed)) * opacityMul,
                tint: tint
            ))
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
