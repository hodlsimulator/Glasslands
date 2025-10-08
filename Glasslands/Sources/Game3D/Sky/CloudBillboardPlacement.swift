//
//  CloudBillboardPlacement.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Blue-noise placements and cauliflower-style cluster construction
//  for billboarded cumulus. Clusters are built as a “pile of balls”:
//  a broad base ring, a tighter crown ring, and a few small up-draft
//  caps, with slight roll variance per puff.
//

import simd
import Foundation

enum CloudBillboardPlacement {

    // MARK: RNG / helpers
    @inline(__always) private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }
    @inline(__always) private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) private static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

    // MARK: Blue-noise-ish placements
    static func poissonDisk(
        _ n: Int, radius R: Float,
        minSepNear: Float, minSepFar: Float,
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
        _ n: Int, r0: Float, r1: Float,
        minSepNear: Float, minSepFar: Float,
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
        let tR = sat((dist - lo) / max(1, hi - lo)) // 0 near → 1 far

        // slightly smaller & fainter with distance so far belt reads as “layer”
        let scale = (1.15 - 0.38 * tR) * scaleMul

        let base: Float      = (560.0 + 320.0 * frand(&seed)) * scale
        let thickness: Float = (280.0 + 210.0 * frand(&seed)) * scale
        let baseLift: Float  = 18.0 + (frand(&seed) - 0.5) * 22.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(14)

        // --- Base ring: 4–6 large puffs
        let baseCount = 4 + Int(frand(&seed) * 2.99)
        let baseRad   = base * 0.50
        for i in 0..<baseCount {
            let a = (Float(i) / Float(baseCount)) * (.pi * 2) + frand(&seed) * 0.35
            let r = baseRad * (0.78 + 0.30 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift,
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.74 + 0.18 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            let puff = CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                     opacity: (0.92 - 0.16 * tR) * opacityMul,
                                     tint: tint)
            puffs.append(puff)
        }

        // --- Crown ring: 3–4 medium puffs, tighter and a little higher
        let crownCount = 3 + Int(frand(&seed) * 2.5)
        let crownRad   = base * 0.34
        for i in 0..<crownCount {
            let a = (Float(i) / Float(crownCount)) * (.pi * 2) + frand(&seed) * 0.42
            let r = crownRad * (0.70 + 0.28 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift + thickness * (0.28 + 0.10 * frand(&seed)),
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.54 + 0.12 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.95 - 0.18 * tR) * opacityMul,
                                       tint: tint))
        }

        // --- Caps: 1–2 small up-drafts to form a cauliflower top
        let capCount = 1 + Int(frand(&seed) * 2.4)
        for _ in 0..<capCount {
            let a = frand(&seed) * (.pi * 2)
            let r = crownRad * (0.25 + 0.30 * frand(&seed))
            let pos = simd_float3(anchorXZ.x + cosf(a) * r,
                                  baseY + baseLift + thickness * (0.55 + 0.20 * frand(&seed)),
                                  anchorXZ.y + sinf(a) * r)
            let size = base * (0.38 + 0.12 * frand(&seed))
            let roll = frand(&seed) * (.pi * 2)
            puffs.append(CloudPuffSpec(pos: pos, size: size, roll: roll, atlasIndex: 0,
                                       opacity: (0.98 - 0.20 * tR) * opacityMul,
                                       tint: tint))
        }

        // --- Slight drift jitter so clusters don’t look stamped
        for i in 0..<puffs.count {
            var p = puffs[i]
            p.pos.x += (frand(&seed) - 0.5) * base * 0.05
            p.pos.z += (frand(&seed) - 0.5) * base * 0.05
            p.roll  += (frand(&seed) - 0.5) * 0.3
            puffs[i] = p
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
