//
//  CloudBillboardPlacement.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Blue-noise placements and cluster construction for billboarded cumulus.
//  This build makes each cluster a FEW large, overlapping puffs so it reads as a
//  single big cloud (no “dozens of tiny bits”). Also reduces plane count → less lag.
//

import Foundation
import simd

enum CloudBillboardPlacement {

    @inline(__always) private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }
    @inline(__always) private static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

    // NOTE: keep signatures the same as your project (no async)
    static func poissonAnnulus(
        _ n: Int, r0: Float, r1: Float,
        minSepNear: Float, minSepFar: Float,
        seed: inout UInt32
    ) -> [simd_float2] {
        var pts: [simd_float2] = []
        pts.reserveCapacity(max(0, n))
        let maxTries = max(1, n) * 3200
        var tries = 0
        let r0sq = max(0, r0 * r0), r1sq = max(r0sq + 1e-5, r1 * r1)
        while pts.count < n && tries < maxTries {
            tries += 1
            let t = frand(&seed)
            let r = sqrt((1 - t) * r0sq + t * r1sq)     // unbiased in area
            let a = frand(&seed) * (.pi * 2)
            let p = simd_float2(cosf(a) * r, sinf(a) * r)
            // interpolate required separation across annulus
            let tr = sat((r - r0) / max(1, r1 - r0))
            let sep = (1 - tr) * minSepNear + tr * minSepFar
            var ok = true
            for q in pts where simd_distance(p, q) < sep { ok = false; break }
            if ok { pts.append(p) }
        }
        return pts
    }

    static func buildCluster(
        at anchorXZ: simd_float2,
        baseY: Float,
        bandSpan: (Float, Float),
        scaleMul: Float,
        opacityMul: Float,
        tint: simd_float3? = nil,
        seed: inout UInt32
    ) -> CloudClusterSpec {

        let (lo, hi) = bandSpan
        let dist = simd_length(anchorXZ)
        let tR = sat((dist - lo) / max(1, hi - lo)) // 0 near → 1 far

        // make clusters larger and more overlapped with distance compensation
        let scale = (1.20 - 0.32 * tR) * scaleMul

        // base cloud size
        let base: Float      = (720.0 + 360.0 * frand(&seed)) * scale
        let thickness: Float = (300.0 + 240.0 * frand(&seed)) * scale
        let baseLift: Float  = 24.0 + (frand(&seed) - 0.5) * 22.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(10)

        // ---- Core: 3 very large overlapping puffs (small radius → strong overlap)
        let coreCount = 3
        let coreRad   = base * 0.32
        for i in 0..<coreCount {
            let a = (Float(i) / Float(coreCount)) * (.pi * 2) + frand(&seed) * 0.33
            let r = coreRad * (0.65 + 0.20 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift,
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (1.18 + 0.16 * frand(&seed))   // BIG
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.94 - 0.10 * tR) * opacityMul,
                                       tint: tint))
        }

        // ---- Crown: 2 large puffs a bit higher
        let crownCount = 2
        let crownRad   = base * 0.24
        for i in 0..<crownCount {
            let a = (Float(i) / Float(crownCount)) * (.pi * 2) + frand(&seed) * 0.45
            let r = crownRad * (0.65 + 0.20 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift + thickness * (0.32 + 0.10 * frand(&seed)),
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.98 + 0.14 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.96 - 0.12 * tR) * opacityMul,
                                       tint: tint))
        }

        // ---- Cap: 1 medium puff on top
        do {
            let a = frand(&seed) * (.pi * 2)
            let r = crownRad * (0.30 + 0.20 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift + thickness * (0.62 + 0.14 * frand(&seed)),
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.78 + 0.12 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.98 - 0.14 * tR) * opacityMul,
                                       tint: tint))
        }

        // ---- Fillers: 2 inner blobs to close tiny gaps, very near centre
        let fillCount = 2
        for _ in 0..<fillCount {
            let a = frand(&seed) * (.pi * 2)
            let r = base * (0.08 + 0.08 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift + thickness * (0.10 + 0.18 * frand(&seed)),
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.68 + 0.10 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.97 - 0.10 * tR) * opacityMul,
                                       tint: tint))
        }

        // slight jitter so clusters don’t stamp
        for i in 0..<puffs.count {
            var p = puffs[i]
            p.pos.x += (frand(&seed) - 0.5) * base * 0.04
            p.pos.z += (frand(&seed) - 0.5) * base * 0.04
            p.roll  += (frand(&seed) - 0.5) * 0.25
            puffs[i] = p
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
