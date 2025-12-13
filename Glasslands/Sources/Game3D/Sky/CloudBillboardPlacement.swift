//
//  CloudBillboardPlacement.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Blue-noise placements and cluster construction for billboarded cumulus.
//  Clusters are intentionally irregular (less symmetry) so silhouettes read more
//  naturally and feel less “blocky”.
//

import simd
import Foundation

enum CloudBillboardPlacement {

    // MARK: - Helpers

    @inline(__always) static func sat(_ x: Float) -> Float { max(0, min(1, x)) }

    @inline(__always) static func frand(_ seed: inout UInt32) -> Float {
        seed = 1664525 &* seed &+ 1013904223
        let v = (seed >> 8) & 0x00FFFFFF
        return Float(v) / Float(0x01000000)
    }

    // MARK: - Poisson-ish annulus distribution

    /// Simple dart-throwing distribution inside an annulus.
    /// Produces a good-enough blue-noise vibe for clouds.
    static func poissonAnnulus(
        count: Int,
        r0: Float,
        r1: Float,
        minSepNear: Float,
        minSepFar: Float,
        seed: inout UInt32
    ) -> [simd_float2] {

        guard count > 0, r1 > r0 else { return [] }

        var points: [simd_float2] = []
        points.reserveCapacity(count)

        let attemptsMax = max(8000, count * 120)
        let twoPi: Float = .pi * 2

        // Separation interpolates across the band to avoid near-clumping.
        func sep(forRadius r: Float) -> Float {
            let t = sat((r - r0) / max(1e-3, (r1 - r0)))
            return (minSepNear * (1 - t)) + (minSepFar * t)
        }

        var attempts = 0
        while points.count < count && attempts < attemptsMax {
            attempts += 1

            let u = frand(&seed)
            let v = frand(&seed)

            // Uniform area in annulus.
            let rr = sqrt(r0 * r0 + u * (r1 * r1 - r0 * r0))
            let a = v * twoPi
            let p = simd_float2(cos(a) * rr, sin(a) * rr)

            let s = sep(forRadius: rr)
            let s2 = s * s

            var ok = true
            for q in points {
                let d = p - q
                if simd_dot(d, d) < s2 {
                    ok = false
                    break
                }
            }
            if ok { points.append(p) }
        }

        return points
    }

    // MARK: - Cluster synthesis

    // NOTE: Keep signatures the same as your project (no async, pure spec build).
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
        let tR = sat((dist - lo) / max(1e-3, (hi - lo)))

        // Mild distance scaling: keep far clouds legible.
        let scale = (1.16 - 0.24 * tR) * scaleMul

        // Base “cluster radius” and vertical depth.
        let base = (780 + 440 * frand(&seed)) * scale
        let thickness = (280 + 520 * frand(&seed)) * scale
        let baseLift = 12 + 28 * frand(&seed)

        let rollBase: Float = (frand(&seed) - 0.5) * 0.55

        // Cluster tint and overall opacity.
        let clusterTint = tint ?? simd_float3(1, 1, 1)
        let clusterOpacity: Float = (0.92 - 0.18 * tR) * opacityMul

        // Small skew so the cluster doesn't look centred / symmetric.
        let skew = simd_float2(
            (frand(&seed) - 0.5) * base * 0.14,
            (frand(&seed) - 0.5) * base * 0.14
        )
        let centreXZ = anchorXZ + skew

        let centre = simd_float3(centreXZ.x, baseY + baseLift, centreXZ.y)

        let twoPi: Float = .pi * 2

        @inline(__always) func randAngle() -> Float { frand(&seed) * twoPi }
        @inline(__always) func randRadius(_ maxR: Float) -> Float { sqrt(frand(&seed)) * maxR }

        @inline(__always) func randAtlasIndex() -> Int { Int(frand(&seed) * 8.0) % 8 }

        var puffs: [CloudPuffSpec] = []
        puffs.reserveCapacity(10)

        func addPuff(
            offsetXZ: simd_float2,
            yFrac: Float,
            sizeMul: Float,
            opacityMulLocal: Float,
            rollJitter: Float
        ) {
            let y = centre.y + thickness * yFrac + (frand(&seed) - 0.5) * (thickness * 0.06)
            let pos = simd_float3(centre.x + offsetXZ.x, y, centre.z + offsetXZ.y)

            let size = base * sizeMul
            let opacity = clusterOpacity * opacityMulLocal

            puffs.append(
                CloudPuffSpec(
                    pos: pos,
                    size: size,
                    roll: rollBase + rollJitter,
                    opacity: opacity,
                    tint: clusterTint,
                    atlasIndex: randAtlasIndex()
                )
            )
        }

        // Core volume: 3 larger puffs near the centre.
        for _ in 0..<3 {
            let a = randAngle()
            let r = randRadius(base * 0.18)
            let off = simd_float2(cos(a) * r, sin(a) * r)

            let yFrac = 0.06 + 0.16 * frand(&seed)
            let sMul = 1.08 + 0.18 * frand(&seed)
            let oMul = 0.92 + 0.10 * frand(&seed)
            let roll = (frand(&seed) - 0.5) * 0.50

            addPuff(offsetXZ: off, yFrac: yFrac, sizeMul: sMul, opacityMulLocal: oMul, rollJitter: roll)
        }

        // Bulk: 2 medium puffs further out to break the outline.
        for _ in 0..<2 {
            let a = randAngle()
            let r = (0.22 + 0.26 * frand(&seed)) * base
            let off = simd_float2(cos(a) * r, sin(a) * r)

            let yFrac = 0.02 + 0.16 * frand(&seed)
            let sMul = 0.92 + 0.20 * frand(&seed)
            let oMul = 0.86 + 0.10 * frand(&seed)
            let roll = (frand(&seed) - 0.5) * 0.45

            addPuff(offsetXZ: off, yFrac: yFrac, sizeMul: sMul, opacityMulLocal: oMul, rollJitter: roll)
        }

        // Crown: 2 smaller puffs higher up.
        for _ in 0..<2 {
            let a = randAngle()
            let r = (0.16 + 0.22 * frand(&seed)) * base
            let off = simd_float2(cos(a) * r, sin(a) * r)

            let yFrac = 0.32 + 0.24 * frand(&seed)
            let sMul = 0.84 + 0.18 * frand(&seed)
            let oMul = 0.80 + 0.10 * frand(&seed)
            let roll = (frand(&seed) - 0.5) * 0.40

            addPuff(offsetXZ: off, yFrac: yFrac, sizeMul: sMul, opacityMulLocal: oMul, rollJitter: roll)
        }

        // Cap: 1 top puff.
        do {
            let a = randAngle()
            let r = (0.06 + 0.12 * frand(&seed)) * base
            let off = simd_float2(cos(a) * r, sin(a) * r)

            let yFrac = 0.66 + 0.18 * frand(&seed)
            let sMul = 0.70 + 0.18 * frand(&seed)
            let oMul = 0.74 + 0.10 * frand(&seed)
            let roll = (frand(&seed) - 0.5) * 0.35

            addPuff(offsetXZ: off, yFrac: yFrac, sizeMul: sMul, opacityMulLocal: oMul, rollJitter: roll)
        }

        // Wisps: 2 small edge puffs to de-block the silhouette.
        for _ in 0..<2 {
            let a = randAngle()
            let r = (0.52 + 0.26 * frand(&seed)) * base
            let off = simd_float2(cos(a) * r, sin(a) * r)

            let yFrac = 0.10 + 0.28 * frand(&seed)
            let sMul = 0.52 + 0.26 * frand(&seed)
            let oMul = 0.52 + 0.10 * frand(&seed)
            let roll = (frand(&seed) - 0.5) * 0.55

            addPuff(offsetXZ: off, yFrac: yFrac, sizeMul: sMul, opacityMulLocal: oMul, rollJitter: roll)
        }

        return CloudClusterSpec(anchorXZ: anchorXZ, puffs: puffs)
    }
}
