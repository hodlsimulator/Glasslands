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

    // MARK: RNG/helpers

    @inline(__always)
    private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always)
    private static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

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
        r0: Float,
        r1: Float,
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
        let tR = sat((dist - lo) / max(1, hi - lo))      // 0 near → 1 far
        let scale = (1.18 - 0.40 * tR) * scaleMul

        let base = (520.0 + 380.0 * frand(&seed)) * scale
        let thickness: Float = (260.0 + 200.0 * frand(&seed)) * scale
        let baseLift: Float = 24.0 + (frand(&seed) - 0.5) * 16.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(12)

        // Base ring (3–5 large puffs)
        let baseCount = 3 + Int(frand(&seed) * 2.8)
        for i in 0..<baseCount {
            let t = (Float(i) + frand(&seed) * 0.25) / Float(max(1, baseCount - 1)) - 0.5
            let offX = t * (base * (0.35 + frand(&seed) * 0.10))
            let offZ = (frand(&seed) - 0.5) * (base * 0.16)
            let s = base * (0.78 + frand(&seed) * 0.22)
            let roll = (frand(&seed) - 0.5) * (.pi * 0.25)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(anchorXZ.x + offX,
                                  baseY + baseLift,
                                  anchorXZ.y + offZ),
                size: s,
                roll: roll,
                atlasIndex: Int(frand(&seed) * 12),
                opacity: (0.90 + frand(&seed) * 0.10) * opacityMul,
                tint: tint
            ))
        }

        // Top cap (1–3)
        let capCount = 1 + Int(frand(&seed) * 2.5)
        for _ in 0..<capCount {
            let offX = (frand(&seed) - 0.5) * (base * 0.18)
            let offZ = (frand(&seed) - 0.5) * (base * 0.18)
            let s = base * (0.52 + frand(&seed) * 0.18)
            let lift = thickness * (0.35 + frand(&seed) * 0.35)
            let roll = (frand(&seed) - 0.5) * (.pi * 0.25)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(anchorXZ.x + offX,
                                  baseY + baseLift + lift,
                                  anchorXZ.y + offZ),
                size: s,
                roll: roll,
                atlasIndex: Int(frand(&seed) * 12),
                opacity: (0.90 + frand(&seed) * 0.10) * opacityMul,
                tint: tint
            ))
        }

        // Side lobes (0–2 each side)
        let sideCount = Int(frand(&seed) * 2.6)
        for dir in [-1, 1] {
            for _ in 0..<sideCount {
                let t = (frand(&seed) * 0.6 + 0.20) * Float(dir)
                let offX = t * (base * (0.55 + frand(&seed) * 0.10))
                let offZ = (frand(&seed) - 0.5) * (base * 0.14)
                let s = base * (0.52 + frand(&seed) * 0.20)
                let roll = (frand(&seed) - 0.5) * (.pi * 0.25)
                puffs.append(CloudPuffSpec(
                    pos: simd_float3(anchorXZ.x + offX,
                                      baseY + baseLift + thickness * (0.12 + frand(&seed) * 0.12),
                                      anchorXZ.y + offZ),
                    size: s,
                    roll: roll,
                    atlasIndex: Int(frand(&seed) * 12),
                    opacity: (0.86 + frand(&seed) * 0.12) * opacityMul,
                    tint: tint
                ))
            }
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
