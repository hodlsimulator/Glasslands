//
//  ZenithCapField.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import Foundation
import simd

/// Planar overhead cloud layer sampled in orthographic projection.
/// Used to avoid circular artefacts/voids right at the zenith.
struct ZenithCapField {
    let size: Int     // square
    private let data: [Float]

    static func build(size: Int, seed: UInt32, densityScale: Float) -> ZenithCapField {
        let cW = max(128, size)
        var field = [Float](repeating: 0, count: cW * cW)

        struct LCG {
            private var s: UInt32
            init(seed: UInt32) { self.s = seed &* 1664525 &+ 1013904223 }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        }
        var rng = LCG(seed: (seed ^ 0xA51C_2C2D) &+ 1)

        // Puff count roughly tracks area and a provided density scale.
        let baseCount = max(400, (cW * cW) / 14)
        let puffCount = Int(Float(baseCount) * max(0.2, densityScale))

        for _ in 0..<puffCount {
            // Uniform disc distribution for centre‑weighted placement.
            let r = sqrt(rng.unit())                    // 0..1, area‑uniform
            let ang = rng.unit() * 2 * .pi
            let px = r * cosf(ang)
            let pz = r * sinf(ang)

            // Tangential orientation with small jitter to avoid radial rings.
            let baseAngle = ang + .pi * 0.5 + (rng.unit() - 0.5) * (.pi * 0.15)
            let ca = cosf(baseAngle), sa = sinf(baseAngle)

            // Anisotropy (wider tangentially near centre).
            let rBase = 0.090 * (0.75 + 0.50 * rng.unit())
            let rx: Float = rBase * (1.60 + 0.60 * (1 - r))
            let ry: Float = rBase * (0.60 + 0.30 * r)

            // Convert to grid.
            let cx = (px * 0.5 + 0.5) * Float(cW)
            let cy = (pz * 0.5 + 0.5) * Float(cW)

            let sx = max(1.0, rx * Float(cW))
            let sy = max(1.0, ry * Float(cW))
            let radX = min(Float(cW), 3.0 * sx)
            let radY = min(Float(cW), 3.0 * sy)

            let x0 = SkyMath.safeIndex(SkyMath.safeFloorInt(cx - radX), 0, cW - 1)
            let x1 = SkyMath.safeIndex(SkyMath.safeFloorInt(cx + radX), 0, cW - 1)
            let y0 = SkyMath.safeIndex(SkyMath.safeFloorInt(cy - radY), 0, cW - 1)
            let y1 = SkyMath.safeIndex(SkyMath.safeFloorInt(cy + radY), 0, cW - 1)
            if x0 > x1 || y0 > y1 { continue }

            // Slight centre boost so zenith never looks empty.
            let amp = 0.85 + 0.35 * (1 - r) + 0.20 * rng.unit()

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

        // Normalise and soften.
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

    /// Bilinear sample in [0,1]x[0,1]. Returns 0 outside the unit disc.
    @inline(__always)
    func sample(u: Float, v: Float) -> Float {
        let uc = SkyMath.clampf(u, 0, 0.99999)
        let vc = SkyMath.clampf(v, 0, 0.99999)

        // Discard outside the unit disc to avoid square corners.
        let dx = uc * 2 - 1
        let dz = vc * 2 - 1
        if dx * dx + dz * dz > 1.0 { return 0 }

        let xf = uc * Float(size) - 0.5
        let yf = vc * Float(size) - 0.5
        let xi = SkyMath.safeFloorInt(xf), yi = SkyMath.safeFloorInt(yf)
        let tx = xf - floorf(xf), ty = yf - floorf(yf)

        let x0 = SkyMath.safeIndex(xi, 0, size - 1), x1 = SkyMath.safeIndex(xi + 1, 0, size - 1)
        let y0 = SkyMath.safeIndex(yi, 0, size - 1), y1 = SkyMath.safeIndex(yi + 1, 0, size - 1)

        let a = data[y0 * size + x0], b = data[y0 * size + x1]
        let c = data[y1 * size + x0], d = data[y1 * size + x1]
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }
}
