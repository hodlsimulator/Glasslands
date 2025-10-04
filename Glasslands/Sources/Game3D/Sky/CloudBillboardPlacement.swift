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

    // MARK: - RNG/helpers
    @inline(__always) private static func frand(_ s: inout UInt32) -> Float {
        s = 1_664_525 &* s &+ 1_013_904_223
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }
    @inline(__always) private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) private static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

    // MARK: - Blue‑noise-ish placements
    static func poissonDisk(_ n: Int, radius R: Float, minSepNear: Float, minSepFar: Float, seed: inout UInt32) -> [simd_float2] {
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

    static func poissonAnnulus(_ n: Int, r0: Float, r1: Float, minSepNear: Float, minSepFar: Float, seed: inout UInt32) -> [simd_float2] {
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
            let tr = sat((r - r0) / (r1 - r0))
            let sep = lerp(minSepNear, minSepFar, powf(tr, 0.8))
            var ok = true
            for q in pts where distance(p, q) < sep { ok = false; break }
            if ok { pts.append(p) }
        }
        return pts
    }

    // MARK: - Cluster construction

    /// Builds a single cauliflower‑like cloud cluster at `anchorXZ`.
    /// `bandSpan` is (nearRadius, farRadius) to normalise distance for tuning.
    static func buildCluster(
        at anchorXZ: simd_float2,
        baseY: Float,
        bandSpan: (Float, Float),
        scaleMul: Float,
        opacityMul: Float,
        seed: inout UInt32
    ) -> CloudClusterSpec {

        let (lo, hi) = bandSpan
        let dist = length(anchorXZ)
        let tR = sat((dist - lo) / max(1, hi - lo))  // 0 near → 1 far

        // Make far clusters *smaller* in world units so they read smaller on screen.
        // Close ones are largest. This is one of the key differences to avoid
        // the “bokeh‑dot field” look and match the photographic reference.
        let scale = (1.18 - 0.40 * tR) * scaleMul

        // Footprint & thickness.
        let base = (520.0 + 380.0 * frand(&seed)) * scale
        let thickness: Float = (260.0 + 200.0 * frand(&seed)) * scale
        let baseLift: Float = 24.0 + (frand(&seed) - 0.5) * 16.0

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(12)

        // ---- Base ring (3–5 large puffs) ----
        let baseCount = 3 + Int(frand(&seed) * 2.8)            // 3..5
        for _ in 0..<baseCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = base * (0.28 + 0.28 * frand(&seed))       // ring-ish
            let sz  = base * (0.82 + 0.18 * frand(&seed))
            let cx = anchorXZ.x + cosf(ang) * rad
            let cz = anchorXZ.y + sinf(ang) * rad
            let cy = baseY + baseLift + (frand(&seed) - 0.5) * (thickness * 0.18)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(cx, cy, cz),
                size: sz,
                roll: (frand(&seed) - 0.5) * 0.6,
                atlasIndex: Int(frand(&seed) * 7.0),
                opacity: (0.92 + 0.06 * frand(&seed)) * opacityMul
            ))
        }

        // ---- Cap (1–2) ----
        let capCount = 1 + Int(frand(&seed) * 1.5)             // 1..2
        for _ in 0..<capCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = base * (0.10 + 0.12 * frand(&seed))
            let sz  = base * (0.90 + 0.16 * frand(&seed))
            let cx = anchorXZ.x + cosf(ang) * rad
            let cz = anchorXZ.y + sinf(ang) * rad
            let cy = baseY + baseLift + thickness * (0.45 + 0.25 * frand(&seed))
            puffs.append(CloudPuffSpec(
                pos: simd_float3(cx, cy, cz),
                size: sz,
                roll: (frand(&seed) - 0.5) * 0.6,
                atlasIndex: Int(frand(&seed) * 7.0),
                opacity: (0.90 + 0.06 * frand(&seed)) * opacityMul
            ))
        }

        // ---- Middle fillers (1–3) ----
        let midCount = 1 + Int(frand(&seed) * 2.5)             // 1..3
        for _ in 0..<midCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = base * (0.08 + 0.36 * frand(&seed))
            let sz  = base * (0.70 + 0.20 * frand(&seed))
            let cx = anchorXZ.x + cosf(ang) * rad
            let cz = anchorXZ.y + sinf(ang) * rad
            let cy = baseY + baseLift + thickness * (0.12 + 0.40 * frand(&seed))
            puffs.append(CloudPuffSpec(
                pos: simd_float3(cx, cy, cz),
                size: sz,
                roll: (frand(&seed) - 0.5) * 0.6,
                atlasIndex: Int(frand(&seed) * 7.0),
                opacity: (0.88 + 0.06 * frand(&seed)) * opacityMul
            ))
        }

        // ---- Skirt (0–2 small edge puffs) ----
        let skirtCount = Int(frand(&seed) * 2.2)               // 0..2
        for _ in 0..<skirtCount {
            let ang = frand(&seed) * (.pi * 2)
            let rad = base * (0.44 + 0.30 * frand(&seed))
            let sz  = base * (0.52 + 0.16 * frand(&seed))
            let cx = anchorXZ.x + cosf(ang) * rad
            let cz = anchorXZ.y + sinf(ang) * rad
            let cy = baseY + baseLift + (frand(&seed) - 0.5) * (thickness * 0.12)
            puffs.append(CloudPuffSpec(
                pos: simd_float3(cx, cy, cz),
                size: sz,
                roll: (frand(&seed) - 0.5) * 0.6,
                atlasIndex: Int(frand(&seed) * 7.0),
                opacity: (0.80 + 0.05 * frand(&seed)) * opacityMul
            ))
        }

        return CloudClusterSpec(puffs: puffs)
    }
}
