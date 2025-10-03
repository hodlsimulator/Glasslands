//
//  CloudFieldLL.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Cumulus cluster field in lat-long space.
//  Produces rounded “pile-of-balls” clusters with a proper horizon/zenith bias.
//

import Foundation
import simd

struct CloudFieldLL {
    let width: Int
    let height: Int
    private let data: [Float]

    // File-private RNG used by the builder and helpers.
    fileprivate struct LCG {
        private var s: UInt32
        init(_ seed: UInt32) { self.s = seed == 0 ? 1 : seed }
        mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
        mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
        mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        mutating func int(_ lo: Int, _ hi: Int) -> Int {
            let u = unit()
            return lo + Int(Float(hi - lo + 1) * u)
        }
    }

    static func build(width: Int, height: Int, coverage: Float, seed: UInt32) -> CloudFieldLL {
        let gW = max(256, width)
        let gH = max(128, height)
        var field = [Float](repeating: 0, count: gW * gH)

        var rng = LCG(seed ^ 0x7F4A_AE13)

        // Jittered grid for blue-noise-ish placement of clusters.
        // More clusters near v≈0.3–0.65, fewer near zenith and near the horizon.
        let rows = max(10, gH / 40)
        for r in 0..<rows {
            let vRow = (Float(r) + 0.5) / Float(rows)
            // 0 at very top/bottom, 1 in the mid-sky band.
            let band = {
                let t = vRow
                let a = SkyMath.smoothstep(0.05, 0.25, t)
                let b = 1.0 - SkyMath.smoothstep(0.72, 0.94, t)
                return a * b
            }()

            let baseCols = max(10, gW / 40)
            let cols = max(6, Int(Float(baseCols) * (0.75 + 1.35 * band)))
            for c in 0..<cols {
                if rng.unit() > coverage { continue }

                let u = (Float(c) + rng.unit()) / Float(cols)
                let v = (Float(r) + rng.unit()) / Float(rows)

                // Keep inside the visible sky band; avoid very bottom (nadir).
                let vClamped = min(0.88, max(0.04, v))

                // Scale with perspective: larger near zenith, smaller near horizon.
                let zen = 1.0 - (vClamped)          // v=0 top → zen=1
                let scale = 0.8 + 0.9 * SkyMath.smooth01(zen)   // 0.8..1.7

                // Base cloud size in pixels.
                let base = (18.0 + 28.0 * rng.unit()) * scale

                addCluster(
                    into: &field, gW: gW, gH: gH,
                    cx: u * Float(gW),
                    cy: vClamped * Float(gH),
                    base: base,
                    rng: &rng
                )
            }
        }

        // Normalise + gentle S-curve to bring out edges.
        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0
        for i in 0..<(gW * gH) {
            var t = field[i] * invMax
            t = max(0, t)
            // Add a little micro detail with 2-octave value noise to avoid flat blobs.
            let nx = (Float(i % gW) + 13.0) * 0.015
            let ny = (Float(i / gW) + 17.0) * 0.015
            let micro = 0.55 * valueFBM(x: nx, y: ny, seed: seed &+ 19, octaves: 2)
            t = t * (0.70 + 0.30 * t) * (0.95 + 0.10 * micro)
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
        cx: Float, cy: Float, base: Float, rng: inout LCG
    ) {
        // Number of constituent puffs (pile-of-balls).
        let n = max(4, min(10, rng.int(6, 9)))

        // Slight upward skew so tops feel cauliflower-like.
        for k in 0..<n {
            let ang = rng.range(-Float.pi, Float.pi)
            let r   = (0.2 + 0.9 * rng.unit()) * base
            let dx  = cosf(ang) * r
            let dy  = sinf(ang) * (r * 0.7) - (0.15 * base)   // push a little downward so base bulks up
            let px  = cx + dx
            let py  = cy + dy

            // Larger, brighter cores near the cluster centre; smaller towards edges.
            let fall = 1.0 - Float(k) / Float(n)
            let puffR = (0.65 + 0.55 * fall) * base
            let amp   = (0.75 + 0.35 * fall) * (0.90 + 0.20 * rng.unit())

            stampPuff(into: &field, gW: gW, gH: gH, cx: px, cy: py, rx: puffR, ry: puffR * 0.92, amp: amp)
        }

        // A couple of small “caplets” on top to suggest recent growth.
        let capCount = rng.int(1, 3)
        for _ in 0..<capCount {
            let px = cx + rng.range(-0.25 * base, 0.25 * base)
            let py = cy - rng.range(0.55 * base, 0.95 * base)
            let puffR: Float = (0.30 + 0.25 * rng.unit()) * base
            let amp: Float = 0.60 + 0.25 * rng.unit()
            stampPuff(into: &field, gW: gW, gH: gH, cx: px, cy: py, rx: puffR, ry: puffR, amp: amp)
        }
    }

    /// Spherical-ish kernel with rounded shoulders; elliptical support.
    private static func stampPuff(
        into field: inout [Float], gW: Int, gH: Int,
        cx: Float, cy: Float, rx: Float, ry: Float, amp: Float
    ) {
        let x0 = max(0, Int(cx - rx * 2 - 2)), x1 = min(gW - 1, Int(cx + rx * 2 + 2))
        let y0 = max(0, Int(cy - ry * 2 - 2)), y1 = min(gH - 1, Int(cy + ry * 2 + 2))
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
                if d2 > 4.0 { continue }

                // Squared-Lorentzian → puffy.
                let k: Float = 1.6
                let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))
                field[gy * gW + gx] += amp * shape
            }
        }
    }

    // Simple value noise + fBm for micro structure.
    private static func valueNoise(x: Float, y: Float, seed: UInt32) -> Float {
        let xi = floorf(x), yi = floorf(y)
        let tx = x - xi, ty = y - yi
        func h(_ X: Int32, _ Y: Int32) -> Float {
            let v = SkyMath.h2(X, Y, seed) & 0xFFFF
            return Float(v) * (1.0 / 65535.0)
        }
        let X = Int32(xi), Y = Int32(yi)
        let a = h(X, Y), b = h(X + 1, Y)
        let c = h(X, Y + 1), d = h(X + 1, Y + 1)
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }

    private static func valueFBM(x: Float, y: Float, seed: UInt32, octaves: Int) -> Float {
        var amp: Float = 0.5
        var freq: Float = 1.0
        var sum: Float = 0
        var s = seed
        for _ in 0..<max(1, octaves) {
            sum += amp * valueNoise(x: x * freq, y: y * freq, seed: s)
            amp *= 0.5
            freq *= 2.0
            s &+= 0x9E37_79B9
        }
        return sum * (1.0 / (1.0 - powf(0.5, Float(max(1, octaves)))))
    }
}
