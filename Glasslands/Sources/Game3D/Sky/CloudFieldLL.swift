//
//  CloudFieldLL.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import Foundation
import simd

/// Low‑resolution lat‑long cloud “puff” field with elliptical blobs and horizon/zenith bias.
/// Field is stored in a width×height grid and bilinearly sampled in (u,v) ∈ [0,1]^2.
struct CloudFieldLL {
    let width: Int
    let height: Int
    private let data: [Float]

    /// Build a deterministic field for the given parameters.
    static func build(width: Int, height: Int, coverage: Float, seed: UInt32) -> CloudFieldLL {
        let gW = max(64, width)
        let gH = max(32, height)
        var field = [Float](repeating: 0, count: gW * gH)

        struct LCG {
            private var s: UInt32
            init(seed: UInt32) { self.s = seed &* 1664525 &+ 1013904223 }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        }
        var rng = LCG(seed: seed != 0 ? seed : 1)

        let baseCount = max(60, (gW * gH) / 80)
        let puffCount = Int(Float(baseCount) * (0.34 / max(0.10, coverage)))

        // Very soft zenith cap to reduce overhead density (keeps zenith blue).
        let capStart: Float = 0.975
        let capEnd:   Float = 0.992

        for _ in 0..<puffCount {
            let u = rng.unit()
            let v = rng.unit()

            // Puff size and anisotropy (elliptical, mostly horizontal).
            let rBase = 0.060 * (0.85 + 0.30 * rng.unit())
            let rx: Float = rBase * (1.30 + 0.40 * rng.unit())
            let ry: Float = rBase * (0.55 + 0.25 * rng.unit())

            // Orientation jitter.
            let maxJitter: Float = .pi * 0.055
            let ang = rng.range(-maxJitter, maxJitter)
            let ca = cosf(ang), sa = sinf(ang)

            // Amplitude: slightly stronger toward horizon.
            let phi = v * .pi
            let upY = cosf(phi)
            let amp = 0.8 + 0.4 * rng.unit()
            let horizonBoost: Float = 0.20 * (1 - SkyMath.clampf(upY, 0, 1))

            // Centre in grid.
            let cx = SkyMath.clampf(u, 0, 0.9999) * Float(gW)
            let cy = SkyMath.clampf(v, 0, 0.9999) * Float(gH)

            let sx = max(1.0, rx * Float(gW))
            let sy = max(1.0, ry * Float(gH))
            let radX = min(Float(gW), 3.0 * sx)
            let radY = min(Float(gH), 3.0 * sy)

            let x0 = SkyMath.safeIndex(SkyMath.safeFloorInt(cx - radX), 0, gW - 1)
            let x1 = SkyMath.safeIndex(SkyMath.safeFloorInt(cx + radX), 0, gW - 1)
            let y0 = SkyMath.safeIndex(SkyMath.safeFloorInt(cy - radY), 0, gH - 1)
            let y1 = SkyMath.safeIndex(SkyMath.safeFloorInt(cy + radY), 0, gH - 1)
            if x0 > x1 || y0 > y1 { continue }

            // Zenith fade so blobs reduce overhead.
            let tFade = SkyMath.smoothstep(capStart, capEnd, SkyMath.clampf(upY, -1, 1))
            let tCap = 1.0 - 0.40 * tFade

            for gy in y0...y1 {
                let yy = (Float(gy) + 0.5) - cy
                // Gravity bias for slightly denser bottoms.
                let gravBias = 1.0 + 0.22 * SkyMath.smoothstep(0, sy * 0.8, max(0, yy))
                for gx in x0...x1 {
                    let xx = (Float(gx) + 0.5) - cx

                    // Rotate into puff local frame and normalise.
                    let xr = (xx * ca - yy * sa) / max(1e-4, sx)
                    let yr = (xx * sa + yy * ca) / max(1e-4, sy)
                    let d2 = xr * xr + yr * yr

                    // Cheap smooth bell: (1 + k d^2)^-2.
                    let k: Float = 1.75
                    let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))

                    let add = (amp + horizonBoost) * shape * tCap * gravBias
                    let idx = gy * gW + gx
                    if add.isFinite { field[idx] += add }
                }
            }
        }

        // Normalise to 0..1 and soften (≈ x^1.2 without pow).
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

    /// Bilinear sample in [0,1]x[0,1].
    @inline(__always)
    func sample(u: Float, v: Float) -> Float {
        let uc = SkyMath.clampf(u, 0, 0.99999)
        let vc = SkyMath.clampf(v, 0, 0.99999)
        let xf = uc * Float(width) - 0.5
        let yf = vc * Float(height) - 0.5
        if !xf.isFinite || !yf.isFinite { return 0 }

        let xi = SkyMath.safeFloorInt(xf), yi = SkyMath.safeFloorInt(yf)
        let tx = xf - floorf(xf), ty = yf - floorf(yf)

        let x0 = SkyMath.safeIndex(xi, 0, width - 1), x1 = SkyMath.safeIndex(xi + 1, 0, width - 1)
        let y0 = SkyMath.safeIndex(yi, 0, height - 1), y1 = SkyMath.safeIndex(yi + 1, 0, height - 1)

        let i00 = y0 * width + x0, i10 = y0 * width + x1
        let i01 = y1 * width + x0, i11 = y1 * width + x1

        let a = data[i00], b = data[i10], c = data[i01], d = data[i11]
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        let v = ab + (cd - ab) * ty
        return v.isFinite ? v : 0
    }
}
