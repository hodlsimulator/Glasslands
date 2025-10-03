//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Equirectangular sky with natural cumulus using deterministic soft "cloud blobs".
//  Crash-safe: no pow/exp/log in inner loops; guarded Float→Int; clamps everywhere.
//  This version biases puffs horizontally and increases overhead coverage (no zenith ring).
//  

import UIKit
import CoreGraphics
import simd

enum SkyGen {
    static func skyWithCloudsImage(
        width: Int = 2048,
        height: Int = 1024,
        coverage: Float = 0.26,
        thickness: Float = 0.30,
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)
        let bpr = W * 4

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
            guard x.isFinite else { return lo }
            return min(hi, max(lo, x))
        }
        @inline(__always) func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
        @inline(__always) func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d)
        }
        @inline(__always) func toByte(_ f: Float) -> UInt8 { UInt8(clampf(f, 0, 1) * 255.0 + 0.5) }
        @inline(__always) func safeFloorInt(_ x: Float) -> Int {
            guard x.isFinite else { return 0 }
            let y = floorf(x)
            if y >= Float(Int.max) { return Int.max }
            if y <= Float(Int.min) { return Int.min }
            return Int(y)
        }
        @inline(__always) func safeIndex(_ i: Int, _ lo: Int, _ hi: Int) -> Int {
            if i < lo { return lo }
            if i > hi { return hi }
            return i
        }

        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Deeper sky gradient
        let top = simd_float3(0.26, 0.55, 0.93)
        let mid = simd_float3(0.52, 0.75, 0.95)
        let bot = simd_float3(0.86, 0.93, 0.98)

        struct LCG {
            private var state: UInt32
            init(seed: UInt32) { self.state = seed &* 1664525 &+ 1013904223 }
            mutating func next() -> UInt32 { state = 1664525 &* state &+ 1013904223; return state }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) } // [0,1)
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        }
        var rng = LCG(seed: seed != 0 ? seed : 1)

        // Low-res cloud density field
        let gW = max(64, W / 3)
        let gH = max(32, H / 3)
        var field = [Float](repeating: 0, count: gW * gH)

        let baseCount = max(60, (gW * gH) / 80)
        let count = Int(Float(baseCount) * (0.34 / max(0.10, coverage)))

        let capStart: Float = 0.975
        let capEnd: Float = 0.992

        for _ in 0..<count {
            let u = rng.unit()
            let v = rng.unit()
            let upY = cosf((v - 0.5) * .pi)

            let rBase = 0.06 + 0.12 * rng.unit()
            let rx = rBase * (1.30 + 0.40 * rng.unit())
            let ry = rBase * (0.55 + 0.25 * rng.unit())

            let maxJitter: Float = .pi * 0.055
            let ang = rng.range(-maxJitter, maxJitter)
            let ca = cosf(ang), sa = sinf(ang)

            let amp = 0.8 + 0.4 * rng.unit()
            let horizonBoost: Float = 0.20 * (1 - clampf(upY, 0, 1))

            let cx = clampf(u, 0, 0.9999) * Float(gW)
            let cy = clampf(v, 0, 0.9999) * Float(gH)
            let sx = max(1.0, rx * Float(gW))
            let sy = max(1.0, ry * Float(gH))
            let radX = min(Float(gW), 3.0 * sx)
            let radY = min(Float(gH), 3.0 * sy)

            let x0 = safeIndex(safeFloorInt(cx - radX), 0, gW - 1)
            let x1 = safeIndex(safeFloorInt(cx + radX), 0, gW - 1)
            let y0 = safeIndex(safeFloorInt(cy - radY), 0, gH - 1)
            let y1 = safeIndex(safeFloorInt(cy + radY), 0, gH - 1)

            let tFade = smoothstep(capStart, capEnd, upY)
            let tCap = 1.0 - 0.40 * tFade

            if x0 > x1 || y0 > y1 { continue }
            for gy in y0...y1 {
                let yy = (Float(gy) + 0.5) - cy
                let gravBias = 1.0 + 0.22 * smoothstep(0, sy * 0.8, max(0, yy))
                for gx in x0...x1 {
                    let xx = (Float(gx) + 0.5) - cx
                    let xr = (xx * ca - yy * sa) / max(1e-4, sx)
                    let yr = (xx * sa + yy * ca) / max(1e-4, sy)
                    let d2 = xr*xr + yr*yr
                    let k: Float = 1.75
                    let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))
                    let add = (amp + horizonBoost) * shape * tCap * gravBias
                    let idx = gy * gW + gx
                    field[idx] += add.isFinite ? add : 0
                }
            }
        }

        // Normalise and gentle contrast
        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0
        for i in 0..<field.count {
            var x = field[i] * invMax
            x = clampf(x, 0, 1)
            field[i] = x * (0.8 + 0.2 * x)
        }

        @inline(__always) func sampleField(u: Float, v: Float) -> Float {
            let uc = clampf(u, 0, 0.99999)
            let vc = clampf(v, 0, 0.99999)
            let xf = uc * Float(gW) - 0.5
            let yf = vc * Float(gH) - 0.5
            if !xf.isFinite || !yf.isFinite { return 0 }
            let xi = safeFloorInt(xf), yi = safeFloorInt(yf)
            let tx = xf - floorf(xf), ty = yf - floorf(yf)
            let x0 = safeIndex(xi, 0, gW - 1), x1 = safeIndex(xi + 1, 0, gW - 1)
            let y0 = safeIndex(yi, 0, gH - 1), y1 = safeIndex(yi + 1, 0, gH - 1)
            let i00 = y0 * gW + x0, i10 = y0 * gW + x1
            let i01 = y1 * gW + x0, i11 = y1 * gW + x1
            let a = field[i00], b = field[i10], c = field[i01], d = field[i11]
            let ab = a + (b - a) * tx
            let cd = c + (d - c) * tx
            let v = ab + (cd - ab) * ty
            return v.isFinite ? v : 0
        }

        // Paint
        for j in 0..<H {
            let v = (Float(j) + 0.5) / Float(H)
            for i in 0..<W {
                let u = (Float(i) + 0.5) / Float(W)

                let azimuth = u * (.pi * 2)
                let elevation = (1 - v) * .pi - (.pi / 2)
                let dir = simd_float3(
                    sinf(azimuth) * cosf(elevation),
                    sinf(elevation),
                    cosf(azimuth) * cosf(elevation)
                )
                let upY = dir.y

                let top = simd_float3(0.26, 0.55, 0.93)
                let mid = simd_float3(0.52, 0.75, 0.95)
                let bot = simd_float3(0.86, 0.93, 0.98)

                let t1 = smoothstep(-0.15, 0.55, upY)
                let base = mix3(bot, mid, t1)
                let t2 = smoothstep(0.25, 0.95, upY)
                let sky = mix3(base, top, t2)

                let jitterBits = (i &* 1664525 &+ j &* 1013904223) & 0xFFFF
                let jitter = (Float(jitterBits) / 65535.0 - 0.5) * 0.04

                var a = smoothstep(coverage + jitter, coverage + jitter + max(0.001, thickness),
                                   sampleField(u: u, v: v))

                var grav = 1 - clampf(upY, 0, 1)
                grav = grav * (0.65 + 0.35 * grav)
                a *= (0.92 + 0.08 * grav)

                let tFade = smoothstep(capStart, capEnd, upY)
                a *= (1.0 - 0.35 * tFade)

                let nd = max(0.0 as Float, simd_dot(simd_normalize(dir), sunDir))
                let nd2 = nd * nd, nd4 = nd2 * nd2, nd8 = nd4 * nd4
                let silver = nd4 * 0.20 + nd8 * 0.30

                let cloudBase: Float = 0.82
                let cloud = simd_float3(repeating: clampf(cloudBase + silver, 0, 1))

                let rgb = mix3(sky, cloud, a)

                let idx = j * bpr + i * 4
                pixels[idx + 0] = toByte(rgb.x)
                pixels[idx + 1] = toByte(rgb.y)
                pixels[idx + 2] = toByte(rgb.z)
                pixels[idx + 3] = 255
            }
        }

        var cg: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let ctx = CGContext(
                data: base,
                width: W,
                height: H,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: cs,
                bitmapInfo: info
            ) {
                cg = ctx.makeImage()
            }
        }
        return cg.map { UIImage(cgImage: $0, scale: 1, orientation: .up) } ?? UIImage()
    }
}
