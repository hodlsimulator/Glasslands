//
//  CloudFieldLL.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Low-resolution lat-long “puff” field with clustering and horizon/zenith bias.
//  The field is bilinearly sampled in (u,v) ∈ [0,1]^2.
//

import Foundation
import simd

struct CloudFieldLL {
    let width: Int
    let height: Int
    private let data: [Float]

    /// Deterministic field for the given parameters.
    static func build(width: Int, height: Int, coverage: Float, seed: UInt32) -> CloudFieldLL {
        let gW = max(128, width)
        let gH = max(64, height)
        var field = [Float](repeating: 0, count: gW * gH)

        struct LCG {
            private var s: UInt32
            init(seed: UInt32) { self.s = (seed == 0 ? 1 : seed) }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
            mutating func normal(_ mu: Float, _ sigma: Float) -> Float {
                let u1 = max(1e-6, unit()), u2 = unit()
                let r = sqrtf(-2.0 * logf(u1)); let t = 2.0 * .pi * u2
                return mu + sigma * r * cosf(t)
            }
        }
        var rng = LCG(seed: seed ^ 0xA51C_2C2D)

        // Roughly constant number of "puffs" across sizes; fewer when coverage is high.
        let baseCount = max(80, (gW * gH) / 60)
        let puffCount = Int(Float(baseCount) * (0.34 / max(0.10, coverage)))

        // Fade the very top of the sky so the zenith never becomes a white cap.
        let zenithFadeStart: Float = 0.96
        let zenithFadeEnd: Float   = 0.995

        for _ in 0..<puffCount {
            // Centre with horizon bias (more puffs towards v ~ 0.55).
            let u = rng.unit()
            let vbias = SkyMath.smoothstep(0.10, 0.90, rng.unit())
            let v = 0.25 + 0.65 * vbias

            let cx = u * Float(gW)
            let cy = v * Float(gH)

            // Elliptical "puff" with mild rotation and scale → produces rounded clumps.
            let theta = rng.range(-.pi, .pi)
            let ca = cosf(theta), sa = sinf(theta)
            let sx = rng.range(6, 26)
            let sy = rng.range(6, 24)
            let amp = 0.7 + 0.6 * rng.unit()     // amplitude variation

            // Slight horizon boost: bigger/brighter puffs lower in the sky.
            let horizonBoost = 0.25 * SkyMath.smoothstep(0.32, 0.75, v)

            // Bounding box in grid space.
            let x0 = max(0, Int(cx - sx * 2 - 2)), x1 = min(gW - 1, Int(cx + sx * 2 + 2))
            let y0 = max(0, Int(cy - sy * 2 - 2)), y1 = min(gH - 1, Int(cy + sy * 2 + 2))
            if x0 > x1 || y0 > y1 { continue }

            // Zenith fade multiplier (prevents "ring" artefacts near the very top).
            let upY = (Float(gH) * 0.5 - cy) / Float(gH) * 2.0 // -1..1 (approx)
            let tFade = SkyMath.smoothstep(zenithFadeStart, zenithFadeEnd, SkyMath.clampf(upY, -1, 1))
            let tCap  = 1.0 - 0.40 * tFade

            for gy in y0...y1 {
                let yy = (Float(gy) + 0.5) - cy

                // Gentle accumulation bias upwards so puffs "stack".
                let gravBias = 1.0 + 0.22 * SkyMath.smoothstep(0, sy * 0.8, max(0, yy))

                for gx in x0...x1 {
                    let xx = (Float(gx) + 0.5) - cx

                    // Rotate & squash to ellipse space.
                    let xr = (xx * ca - yy * sa) / max(1e-4, sx)
                    let yr = (xx * sa + yy * ca) / max(1e-4, sy)
                    let d2 = xr * xr + yr * yr

                    // Squared–Lorentzian falloff → rounded shoulders.
                    let k: Float = 1.75
                    let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))
                    let add = (amp + horizonBoost) * shape * tCap * gravBias
                    field[gy * gW + gx] += add.isFinite ? add : 0
                }
            }
        }

        // Normalise and give density a mild "S" curve (brings out edges).
        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0
        for i in 0..<(gW * gH) {
            var t = field[i] * invMax
            t = max(0, t)
            t = t * (0.70 + 0.30 * t)
            field[i] = t
        }

        return CloudFieldLL(width: gW, height: gH, data: field)
    }

    /// Bilinear sample in [0,1]^2.
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

        let i00 = y0 * width + x0, i10 = y0 * width + x1
        let i01 = y1 * width + x0, i11 = y1 * width + x1

        let a = data[i00], b = data[i10], c = data[i01], d = data[i11]
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        let v  = ab + (cd - ab) * ty
        return v.isFinite ? v : 0
    }
}
