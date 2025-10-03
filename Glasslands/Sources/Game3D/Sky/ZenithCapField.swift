//
//  ZenithCapField.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Orthographic overhead layer to avoid circular voids at the zenith.
//  Sampled in a unit disc; returns 0 outside it.
//

import Foundation
import simd

struct ZenithCapField {
    let size: Int // square
    private let data: [Float]

    static func build(size: Int, seed: UInt32, densityScale: Float) -> ZenithCapField {
        let cW = max(128, size)
        var field = [Float](repeating: 0, count: cW * cW)

        struct LCG {
            private var s: UInt32
            init(seed: UInt32) { self.s = (seed == 0 ? 1 : seed) }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        }
        var rng = LCG(seed: (seed ^ 0xC0FF_EE01) &+ 1)

        let baseCount = max(400, (cW * cW) / 14)
        let puffCount = Int(Float(baseCount) * max(0.2, densityScale))

        for _ in 0..<puffCount {
            // Disc distribution, denser near centre; small random tilt/scale.
            let r = sqrtf(rng.unit()) * 0.95
            let a = rng.range(-.pi, .pi)
            let rx = r * cosf(a), rz = r * sinf(a)
            let cx = (rx * 0.5 + 0.5) * Float(cW)
            let cy = (rz * 0.5 + 0.5) * Float(cW)

            let theta = rng.range(-.pi, .pi)
            let ca = cosf(theta), sa = sinf(theta)
            let sx = rng.range(6.0, 22.0)
            let sy = rng.range(6.0, 22.0)

            let x0 = max(0, Int(cx - sx * 2 - 2)), x1 = min(cW - 1, Int(cx + sx * 2 + 2))
            let y0 = max(0, Int(cy - sy * 2 - 2)), y1 = min(cW - 1, Int(cy + sy * 2 + 2))
            if x0 > x1 || y0 > y1 { continue }

            // Slight centre boost so zenith never looks empty.
            let amp = 0.85 + 0.35 * (1 - sqrtf(rx*rx + rz*rz)) + 0.20 * rng.unit()

            for gy in y0...y1 {
                let yy = (Float(gy) + 0.5) - cy
                for gx in x0...x1 {
                    let xx = (Float(gx) + 0.5) - cx
                    let xr = (xx * ca - yy * sa) / max(1e-4, sx)
                    let yr = (xx * sa + yy * ca) / max(1e-4, sy)
                    let d2 = xr * xr + yr * yr
                    let k: Float = 1.6
                    let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))
                    field[gy * cW + gx] += amp * shape
                }
            }
        }

        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0
        for i in 0..<(cW * cW) {
            var t = field[i] * invMax
            t = max(0, t)
            t = t * (0.70 + 0.30 * t)
            field[i] = t
        }

        return ZenithCapField(size: cW, data: field)
    }

    /// Bilinear sample; returns 0 outside the unit disc.
    @inline(__always)
    func sample(u: Float, v: Float) -> Float {
        let uc = SkyMath.clampf(u, 0, 0.99999)
        let vc = SkyMath.clampf(v, 0, 0.99999)
        let dx = uc * 2 - 1
        let dz = vc * 2 - 1
        if dx * dx + dz * dz > 1.0 { return 0 }       // outside disc

        let xf = uc * Float(size) - 0.5
        let yf = vc * Float(size) - 0.5

        let xi = SkyMath.safeFloorInt(xf)
        let yi = SkyMath.safeFloorInt(yf)
        let tx = xf - floorf(xf)
        let ty = yf - floorf(yf)

        let x0 = SkyMath.safeIndex(xi    , 0, size - 1)
        let x1 = SkyMath.safeIndex(xi + 1, 0, size - 1)
        let y0 = SkyMath.safeIndex(yi    , 0, size - 1)
        let y1 = SkyMath.safeIndex(yi + 1, 0, size - 1)

        let a = data[y0 * size + x0], b = data[y0 * size + x1]
        let c = data[y1 * size + x0], d = data[y1 * size + x1]
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }
}
