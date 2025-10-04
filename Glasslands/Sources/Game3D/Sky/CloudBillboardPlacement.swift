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

@inline(__always) private func cbpRandf(_ s: inout UInt32) -> Float {
    s = 1_664_525 &* s &+ 1_013_904_223
    return Float(s >> 8) * (1.0 / 16_777_216.0)
}

@inline(__always) private func cbpLerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) private func cbpSat(_ x: Float) -> Float { max(0, min(1, x)) }

/// Poisson-disk sampling in an annulus (pure math, thread-safe).
func cbpPoissonAnnulus(
    _ n: Int,
    r0: Float,
    r1: Float,
    minSepNear: Float,
    minSepFar: Float,
    seed: inout UInt32
) -> [simd_float2] {
    var pts: [simd_float2] = []
    pts.reserveCapacity(n)

    let maxTries = max(1, n) * 3200
    var tries = 0

    while pts.count < n && tries < maxTries {
        tries += 1
        let t  = cbpRandf(&seed)
        let rr = sqrt(cbpLerp(r0 * r0, r1 * r1, t))
        let a  = cbpRandf(&seed) * (.pi * 2)
        let p  = simd_float2(cosf(a) * rr, sinf(a) * rr)

        let tr  = cbpSat((rr - r0) / max(1, r1 - r0))
        let sep = cbpLerp(minSepNear, minSepFar, powf(tr, 0.8))

        var ok = true
        for q in pts where distance(p, q) < sep { ok = false; break }
        if ok { pts.append(p) }
    }
    return pts
}

/// Build a single cloud cluster spec (pure math, thread-safe).
func cbpBuildCluster(
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
    let tR = cbpSat((dist - lo) / max(1, hi - lo))  // 0 near → 1 far

    let scale = (1.18 - 0.40 * tR) * scaleMul
    let base = (520.0 + 380.0 * cbpRandf(&seed)) * scale
    let thickness: Float = (260.0 + 200.0 * cbpRandf(&seed)) * scale
    let baseLift: Float = 24.0 + (cbpRandf(&seed) - 0.5) * 16.0

    var puffs: [CloudPuffSpec] = []
    puffs.reserveCapacity(12)

    // Base ring (3–5 large puffs)
    let baseCount = 3 + Int(cbpRandf(&seed) * 2.8)
    for _ in 0..<baseCount {
        let ang = cbpRandf(&seed) * (.pi * 2)
        let rad = 110.0 + cbpRandf(&seed) * 90.0
        let sz  = 420.0 + cbpRandf(&seed) * 220.0
        let x = anchorXZ.x + cosf(ang) * rad
        let z = anchorXZ.y + sinf(ang) * rad
        let y = baseY + base + baseLift
        let op = 0.92 - 0.15 * tR
        puffs.append(CloudPuffSpec(
            pos: simd_float3(x, y, z),
            size: sz,
            roll: cbpRandf(&seed) * .pi,
            atlasIndex: Int(cbpRandf(&seed) * 1000) % 6,
            opacity: max(0.0, min(1.0, op)) * opacityMul,
            tint: tint
        ))
    }

    // Top cap (smaller, lifting the silhouette)
    let capCount = 2 + Int(cbpRandf(&seed) * 2.0)
    for _ in 0..<capCount {
        let ang = cbpRandf(&seed) * (.pi * 2)
        let rad = 60.0 + cbpRandf(&seed) * 70.0
        let sz  = 260.0 + cbpRandf(&seed) * 180.0
        let x = anchorXZ.x + cosf(ang) * rad
        let z = anchorXZ.y + sinf(ang) * rad
        let y = baseY + base + thickness
        let op = 0.86 - 0.18 * tR
        puffs.append(CloudPuffSpec(
            pos: simd_float3(x, y, z),
            size: sz,
            roll: cbpRandf(&seed) * .pi,
            atlasIndex: Int(cbpRandf(&seed) * 1000) % 6,
            opacity: max(0.0, min(1.0, op)) * opacityMul,
            tint: tint
        ))
    }

    return CloudClusterSpec(puffs: puffs)
}
