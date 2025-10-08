//
//  CloudFieldLL.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Lat–long cumulus field used for placement/coverage.
//  This build generates FEWER, BIGGER clusters with a clear gap between
//  clouds. It avoids the tiny-speck look and cuts draw calls → less lag.
//

import Foundation
import simd

struct CloudFieldLL {
    let width: Int
    let height: Int
    private let data: [Float]

    // MARK: - Builder

    fileprivate struct LCG {
        private var s: UInt32
        init(_ seed: UInt32) { self.s = seed == 0 ? 1 : seed }
        mutating func next() -> UInt32 { s = 1_664_525 &* s &+ 1_013_904_223; return s }
        mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
        mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        mutating func int(_ lo: Int, _ hi: Int) -> Int {
            let u = unit(); return lo + Int(Float(hi - lo + 1) * u)
        }
    }

    static func build(width: Int, height: Int, coverage: Float, seed: UInt32) -> CloudFieldLL {
        let gW = max(512, width)     // slightly higher base so interpolation looks good
        let gH = max(256, height)

        var field = [Float](repeating: 0, count: gW * gH)
        var rng = LCG(seed ^ 0x7F4A_AE13)

        // ---- Poisson-disk cluster centres (small count, proper separation) ----
        // 22..44 clusters; higher coverage → more clusters, but still “dozens”, not hundreds.
        let cov = max(0.02, min(0.98, coverage))
        let targetClusters = max(18, min(44, Int(round(22.0 + cov * 22.0))))

        // minimum centre spacing in *pixels* (wider spacing at higher coverage)
        let sepBasePx: Float = 140.0 * (0.80 + 0.35 * cov)   // 112..175 px

        var centres: [(u: Float, v: Float, base: Float)] = []
        centres.reserveCapacity(targetClusters)

        var darts = 0
        let maxDarts = targetClusters * 800

        while centres.count < targetClusters && darts < maxDarts {
            darts += 1

            // bias away from extreme zenith/horizon for nicer banding
            let vRaw = rng.unit()
            let v = min(0.88, max(0.12, vRaw * 0.88 + 0.06))
            let zen = 1.0 - v
            let u = rng.unit()

            // bigger clusters towards zenith (perspective)
            let sizeScale = 0.95 + 1.10 * SkyMath.smooth01(zen)     // ≈0.95..2.05
            let base = (48.0 + 44.0 * rng.unit()) * sizeScale       // base puff radius in px

            // Poisson spacing in pixels; slightly larger near zenith
            let sepPx = sepBasePx * (0.88 + 0.35 * SkyMath.smooth01(zen))

            var ok = true
            for c in centres {
                let du = (u - c.u) * Float(gW)
                let dv = (v - c.v) * Float(gH)
                if (du*du + dv*dv) < (sepPx * sepPx) { ok = false; break }
            }
            if !ok { continue }

            centres.append((u, v, base))
        }

        // ---- Splat each cluster as a “pile of balls” with a crown (fills interior) ----
        for c in centres {
            addCluster(into: &field,
                       gW: gW, gH: gH,
                       cx: c.u * Float(gW),
                       cy: c.v * Float(gH),
                       base: c.base,
                       rng: &rng)
        }

        // ---- Normalise + gentle S-curve + a breath of micro noise (cheap) ----
        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0

        for i in 0..<(gW * gH) {
            var t = max(0, field[i] * invMax)
            // two-octave value fBm just to avoid “airbrushed” edges
            let nx = (Float(i % gW) + 13.0) * 0.010
            let ny = (Float(i / gW) + 17.0) * 0.010
            let micro = 0.40 * valueFBM(x: nx, y: ny, seed: seed &+ 19, octaves: 2)

            // slight contrast curve + micro
            t = t * (0.72 + 0.28 * t) * (0.96 + micro)
            field[i] = t
        }

        return CloudFieldLL(width: gW, height: gH, data: field)
    }

    // MARK: - Sampling

    @inline(__always)
    func sample(u: Float, v: Float) -> Float {
        let uc = SkyMath.clampf(u, 0, 0.99999)
        let vc = SkyMath.clampf(v, 0, 0.99999)
        let xf = uc * Float(width)  - 0.5
        let yf = vc * Float(height) - 0.5
        if !xf.isFinite || !yf.isFinite { return 0 }

        let xi = SkyMath.safeFloorInt(xf)
        let yi = SkyMath.safeFloorInt(yf)
        let tx = xf - floorf(xf)
        let ty = yf - floorf(yf)

        let x0 = SkyMath.safeIndex(xi    , 0, width  - 1)
        let x1 = SkyMath.safeIndex(xi + 1, 0, width  - 1)
        let y0 = SkyMath.safeIndex(yi    , 0, height - 1)
        let y1 = SkyMath.safeIndex(yi + 1, 0, height - 1)

        let a = data[y0 * width + x0], b = data[y0 * width + x1]
        let c = data[y1 * width + x0], d = data[y1 * width + x1]
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }

    // MARK: - Internals

    private static func addCluster(
        into field: inout [Float], gW: Int, gH: Int,
        cx: Float, cy: Float, base: Float,
        rng: inout LCG
    ) {
        // 14–22 constituent puffs → solid fill without holes
        let n = max(14, min(22, rng.int(16, 22)))

        for k in 0..<n {
            // ring + crown; slight upward skew to form a cauliflower top
            let a = (Float(k) / Float(n)) * (.pi * 2.0) + rng.unit() * 0.35
            let r = base * (0.22 + 0.65 * sqrtf(rng.unit()))
            let up = base * (0.10 + 0.25 * rng.unit())
            let px = cx + cosf(a) * r
            let py = cy - 0.22 * r + up

            let rx = base * (0.85 + 0.25 * rng.unit())
            let ry = base * (0.72 + 0.22 * rng.unit())
            splatLorentzian(into: &field, gW: gW, gH: gH, cx: px, cy: py, rx: rx, ry: ry,
                            amp: 1.0 + 0.35 * rng.unit())
        }
    }

    private static func splatLorentzian(
        into field: inout [Float], gW: Int, gH: Int,
        cx: Float, cy: Float, rx: Float, ry: Float, amp: Float
    ) {
        let x0 = max(0, Int(floor(cx - 3.0 * rx)))
        let x1 = min(gW - 1, Int(ceil(cx + 3.0 * rx)))
        let y0 = max(0, Int(floor(cy - 3.0 * ry)))
        let y1 = min(gH - 1, Int(ceil(cy + 3.0 * ry)))
        if x0 > x1 || y0 > y1 { return }

        let invRx = 1.0 / max(1e-4, rx)
        let invRy = 1.0 / max(1e-4, ry)

        for gy in y0...y1 {
            let yy = (Float(gy) + 0.5) - cy
            let yr = yy * invRy
            for gx in x0...x1 {
                let xx = (Float(gx) + 0.5) - cx
                let xr = xx * invRx
                let d2 = xr * xr + yr * yr
                if d2 > 4.0 { continue } // small clamp

                // Squared-Lorentzian → puffy, fills well when overlapped
                let k: Float = 1.6
                let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))
                field[gy * gW + gx] += amp * shape
            }
        }
    }

    // Simple value noise + fBm for micro structure
    private static func valueNoise(x: Float, y: Float, seed: UInt32) -> Float {
        let xi = floorf(x), yi = floorf(y)
        let tx = x - xi, ty = y - yi
        func h(_ X: Int32, _ Y: Int32) -> Float {
            let v = SkyMath.h2(X, Y, seed) & 0xFFFF
            return Float(v) * (1.0 / 65535.0)
        }
        let X = Int32(xi), Y = Int32(yi)
        let a = h(X, Y),     b = h(X + 1, Y)
        let c = h(X, Y + 1), d = h(X + 1, Y + 1)
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }

    private static func valueFBM(x: Float, y: Float, seed: UInt32, octaves: Int) -> Float {
        var amp: Float = 0.5
        var freq: Float = 1.0
        var sum:  Float = 0
        var s = seed
        for _ in 0..<max(1, octaves) {
            sum += amp * valueNoise(x: x * freq, y: y * freq, seed: s)
            amp *= 0.5
            freq *= 2.02
            s &+= 0x9E37_79B9
        }
        return sum
    }
}
