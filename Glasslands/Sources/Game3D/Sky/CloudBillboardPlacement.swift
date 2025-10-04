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

    static func poissonAnnulus(
        _ n: Int,
        r0: Float,
        r1: Float,
        minSepNear: Float,
        minSepFar: Float,
        seed: inout UInt32
    ) -> [simd_float2] {
        @inline(__always) func randf(_ s: inout UInt32) -> Float {
            s = 1_664_525 &* s &+ 1_013_904_223
            return Float(s >> 8) * (1.0 / 16_777_216.0)
        }
        @inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        @inline(__always) func sat(_ x: Float) -> Float { max(0, min(1, x)) }

        var pts: [simd_float2] = []
        pts.reserveCapacity(n)
        let maxTries = max(1, n) * 3200
        var tries = 0

        while pts.count < n && tries < maxTries {
            tries += 1
            let t  = randf(&seed)
            let rr = sqrt(lerp(r0 * r0, r1 * r1, t))
            let a  = randf(&seed) * (.pi * 2)
            let p  = simd_float2(cosf(a) * rr, sinf(a) * rr)

            let tr  = sat((rr - r0) / max(1, r1 - r0))
            let sep = lerp(minSepNear, minSepFar, powf(tr, 0.8))

            var ok = true
            for q in pts where distance(p, q) < sep { ok = false; break }
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
        @inline(__always) func randf(_ s: inout UInt32) -> Float {
            s = 1_664_525 &* s &+ 1_013_904_223
            return Float(s >> 8) * (1.0 / 16_777_216.0)
        }
        @inline(__always) func sat(_ x: Float) -> Float { max(0, min(1, x)) }

        let (lo, hi) = bandSpan
        let dist = length(anchorXZ)
        let tR = sat((dist - lo) / max(1, hi - lo))  // 0 near → 1 far

        let scale = (1.18 - 0.40 * tR) * scaleMul
        let base = (520.0 + 380.0 * randf(&seed)) * scale
        let thickness: Float = (260.0 + 200.0 * randf(&seed)) * scale
        let baseLift: Float = 24.0 + (randf(&seed) - 0.5) * 16.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(12)

        // Base ring (3–5 large puffs)
        let baseCount = 3 + Int(randf(&seed) * 2.8)
        for _ in 0..<baseCount {
            let ang = randf(&seed) * (.pi * 2)
            let rad = 110.0 + randf(&seed) * 90.0
            let sz  = 420.0 + randf(&seed) * 220.0
            let x = anchorXZ.x + cosf(ang) * rad
            let z = anchorXZ.y + sinf(ang) * rad
            let y = baseY + base + baseLift
            let op = 0.92 - 0.15 * tR
            puffs.append(CloudPuffSpec(
                pos: simd_float3(x, y, z),
                size: sz,
                roll: randf(&seed) * .pi,
                atlasIndex: Int(randf(&seed) * 1000) % 6,
                opacity: max(0.0, min(1.0, op)) * opacityMul,
                tint: tint
            ))
        }

        // Top cap (smaller, lifting the silhouette)
        let capCount = 2 + Int(randf(&seed) * 2.0)
        for _ in 0..<capCount {
            let ang = randf(&seed) * (.pi * 2)
            let rad = 60.0 + randf(&seed) * 70.0
            let sz  = 260.0 + randf(&seed) * 180.0
            let x = anchorXZ.x + cosf(ang) * rad
            let z = anchorXZ.y + sinf(ang) * rad
            let y = baseY + base + thickness
            let op = 0.86 - 0.18 * tR
            puffs.append(CloudPuffSpec(
                pos: simd_float3(x, y, z),
                size: sz,
                roll: randf(&seed) * .pi,
                atlasIndex: Int(randf(&seed) * 1000) % 6,
                opacity: max(0.0, min(1.0, op)) * opacityMul,
                tint: tint
            ))
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
