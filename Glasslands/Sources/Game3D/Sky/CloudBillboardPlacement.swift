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
    @inline(__always) private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }
    @inline(__always) private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) private static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

    static func poissonDisk(
        _ n: Int, radius R: Float,
        minSepNear: Float, minSepFar: Float,
        seed: inout UInt32
    ) -> [simd_float2] {
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
            for q in pts where distance(p, q) < sep { ok = false; break }
            if ok { pts.append(p) }
        }
        return pts
    }

    static func poissonAnnulus(
        _ n: Int, r0: Float, r1: Float,
        minSepNear: Float, minSepFar: Float,
        seed: inout UInt32
    ) -> [simd_float2] {
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
        let (lo, hi) = bandSpan
        let dist = length(anchorXZ)
        let tR = sat((dist - lo) / max(1, hi - lo))  // 0 near → 1 far

        let scale = (1.18 - 0.40 * tR) * scaleMul
        let base = (520.0 + 380.0 * frand(&seed)) * scale
        let thickness: Float = (260.0 + 200.0 * frand(&seed)) * scale
        let baseLift: Float = 24.0 + (frand(&seed) - 0.5) * 16.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(12)

        // Base ring (3–5 large puffs)
        let baseCount = 3 + Int(frand(&seed) * 2.8)
        for _ in 0..<baseCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = 110.0 + frand(&seed) * 90.0
            let sz  = 420.0 + frand(&seed) * 220.0
            let x = anchorXZ.x + cosf(ang) * rad
            let z = anchorXZ.y + sinf(ang) * rad
            let y = baseY + base + baseLift
            let op = 0.92 - 0.15 * tR
            puffs.append(CloudPuffSpec(
                pos: simd_float3(x, y, z), size: sz, roll: frand(&seed) * .pi,
                atlasIndex: Int(frand(&seed) * 1000) % 6,
                opacity: max(0.0, min(1.0, op)) * opacityMul,
                tint: tint
            ))
        }

        // Top cap (smaller, lifting the silhouette)
        let capCount = 2 + Int(frand(&seed) * 2.0)
        for _ in 0..<capCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = 60.0 + frand(&seed) * 70.0
            let sz  = 260.0 + frand(&seed) * 180.0
            let x = anchorXZ.x + cosf(ang) * rad
            let z = anchorXZ.y + sinf(ang) * rad
            let y = baseY + base + thickness
            let op = 0.86 - 0.18 * tR
            puffs.append(CloudPuffSpec(
                pos: simd_float3(x, y, z), size: sz, roll: frand(&seed) * .pi,
                atlasIndex: Int(frand(&seed) * 1000) % 6,
                opacity: max(0.0, min(1.0, op)) * opacityMul,
                tint: tint
            ))
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
