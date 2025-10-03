//
//  CumulusRenderer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Pure compute (no UIKit/SceneKit). Safe to call from any thread/actor.
//

import Foundation
import simd

struct CumulusPixels: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

struct CumulusRenderer {

    // MARK: - Math helpers (actor-agnostic)

    @inline(__always) nonisolated private static func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        x.isFinite ? min(hi, max(lo, x)) : lo
    }

    @inline(__always) nonisolated private static func smooth01(_ x: Float) -> Float {
        let t = clampf(x, 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) nonisolated private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let d = e1 - e0
        return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d)
    }

    @inline(__always) nonisolated private static func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 {
        a + (b - a) * t
    }

    @inline(__always) nonisolated private static func toByte(_ f: Float) -> UInt8 {
        UInt8(clampf(f, 0, 1) * 255.0 + 0.5)
    }

    @inline(__always) nonisolated private static func safeFloorInt(_ x: Float) -> Int {
        guard x.isFinite else { return 0 }
        let y = floorf(x)
        if y >= Float(Int.max) { return Int.max }
        if y <= Float(Int.min) { return Int.min }
        return Int(y)
    }

    @inline(__always) nonisolated private static func safeIndex(_ i: Int, _ lo: Int, _ hi: Int) -> Int {
        (i < lo) ? lo : (i > hi ? hi : i)
    }

    @inline(__always) nonisolated private static func wrapIndex(_ i: Int, _ n: Int) -> Int {
        let m = i % n
        return m < 0 ? m + n : m
    }

    // MARK: - Sky generator

    nonisolated static func computePixels(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = 0.34,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63
    ) -> CumulusPixels {

        let W = max(256, width)
        let H = max(128, height)

        // Low-res “puff field” we’ll upsample.
        let FW = max(256, W / 2)
        let FH = max(128, H / 2)
        var field = [Float](repeating: 0, count: FW * FH)

        struct LCG {
            private var s: UInt32
            init(_ seed: UInt32) { s = seed != 0 ? seed : 1 }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
            mutating func norm(_ mu: Float, _ sigma: Float) -> Float {
                let u1 = max(1e-6, unit())
                let u2 = unit()
                let r = sqrtf(-2.0 * logf(u1))
                let t = 2.0 * .pi * u2
                return mu + sigma * r * cosf(t)
            }
        }
        var rng = LCG(seed ^ 0xA51C_2C2D)

        // Cluster distribution: smaller/denser near horizon, larger up high, with some at zenith.
        let clusterCount = max(36, (FW * FH) / 24_000)
        for _ in 0..<clusterCount {
            let cx = rng.range(0, Float(FW) - 1)
            let cy = rng.range(0, Float(FH) - 1)

            let amp: Float = 0.75 + 0.55 * rng.unit()
            let rx:  Float = 2.2 + 5.8 * rng.unit()
            let ry:  Float = 1.8 + 5.4 * rng.unit()
            let theta = rng.range(0, 2 * .pi)
            let cth = cosf(theta), sth = sinf(theta)

            let y0 = max(0, safeFloorInt(cy - 3 * ry))
            let y1 = min(FH - 1, safeFloorInt(cy + 3 * ry))
            if y0 > y1 { continue }

            // Limit x-range but allow wrapping so clusters at edges contribute on both sides.
            let xMin = safeFloorInt(cx - 3 * rx) - FW
            let xMax = safeFloorInt(cx + 3 * rx) + FW

            for yy in y0...y1 {
                let Y = (Float(yy) + 0.5) - cy
                let bottom = smooth01(clampf((Y + 0.5 * ry) / (2.0 * ry), 0, 1))
                let gravBias: Float = 1.0 + 0.22 * bottom

                var xx = xMin
                while xx <= xMax {
                    let xw0 = wrapIndex(xx, FW)

                    let X = (Float(xx) + 0.5) - cx
                    let xr = (X * cth - Y * sth) / max(1e-4, rx)
                    let yr = (X * sth + Y * cth) / max(1e-4, ry)
                    let d2 = xr * xr + yr * yr
                    let kBase: Float = 1.55 + 0.50 * rng.unit()
                    let shape = 1.0 / ((1.0 + kBase * d2) * (1.0 + kBase * d2))

                    field[yy * FW + xw0] += amp * shape * gravBias

                    // If this sample fell outside, mirror its contribution into the wrapped location too.
                    if xx < 0 || xx >= FW {
                        let xw1 = wrapIndex(xx < 0 ? xx + FW : xx - FW, FW)
                        field[yy * FW + xw1] += amp * shape * gravBias
                    }

                    xx += 1
                }
            }
        }

        // Normalise and soften.
        var maxVal: Float = 0
        for v in field where v.isFinite && v > maxVal { maxVal = v }
        let invMax = maxVal > 0 ? (1.0 / maxVal) : 1.0
        for i in 0..<(FW * FH) {
            var t = field[i] * invMax
            t = max(0, t)
            t = t * (0.70 + 0.30 * t) // mild contrast curve
            field[i] = t
        }

        let edge = clampf(edgeSoftness, 0.10, 0.35)
        let thresh = clampf(0.58 - 0.36 * coverage, 0.32, 0.68)

        // Raster to RGBA8.
        var out = [UInt8](repeating: 0, count: W * H * 4)

        // Sun lighting.
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        var sunDir = simd_float3(sinf(sunAz) * cosf(sunEl), sinf(sunEl), cosf(sunAz) * cosf(sunEl))
        sunDir = simd_normalize(sunDir)

        // Sky gradient.
        let SKY_TOP = simd_float3(0.30, 0.56, 0.96)
        let SKY_MID = simd_float3(0.56, 0.74, 0.96)
        let SKY_BOT = simd_float3(0.88, 0.93, 0.99)

        @inline(__always)
        func sampleField(u: Float, v: Float) -> Float {
            let uc = clampf(u, 0, 0.99999)
            let vc = clampf(v, 0, 0.99999)
            let xf = uc * Float(FW) - 0.5
            let yf = vc * Float(FH) - 0.5
            let xi = safeFloorInt(xf), yi = safeFloorInt(yf)
            let tx = xf - floorf(xf), ty = yf - floorf(yf)
            let x0 = safeIndex(xi, 0, FW - 1), x1 = safeIndex(xi + 1, 0, FW - 1)
            let y0 = safeIndex(yi, 0, FH - 1), y1 = safeIndex(yi + 1, 0, FH - 1)
            let i00 = y0 * FW + x0, i10 = y0 * FW + x1
            let i01 = y1 * FW + x0, i11 = y1 * FW + x1
            let a = field[i00], b = field[i10], c = field[i01], d = field[i11]
            let ab = a + (b - a) * tx
            let cd = c + (d - c) * tx
            return ab + (cd - ab) * ty
        }

        @inline(__always)
        func gradField(u: Float, v: Float) -> (Float, Float) {
            let du: Float = 1.0 / Float(FW)
            let dv: Float = 1.0 / Float(FH)
            let p  = sampleField(u: u, v: v)
            let px = sampleField(u: u + du, v: v)
            let py = sampleField(u: u, v: v + dv)
            return (px - p, py - p)
        }

        let invW = 1.0 / Float(W)
        let invH = 1.0 / Float(H)

        for j in 0..<H {
            let v = Float(j) * invH

            // Smooth three-stop gradient (bottom→mid→top).
            let g0 = smooth01(min(1, v * 2))               // bottom→mid
            let g1 = smooth01(min(1, max(0, (v - 0.5) * 2))) // mid→top
            let skyBase = mix3(mix3(SKY_BOT, SKY_MID, g0), mix3(SKY_MID, SKY_TOP, g1), 0.15 * smooth01(abs(2 * v - 1)))

            // Elevation for equirectangular mapping.
            let theta = .pi * v // 0 at top, π at bottom

            for i in 0..<W {
                let u = Float(i) * invW

                // Cloud density from field.
                let d = sampleField(u: u, v: v)
                let t = smoothstep(thresh - edge, thresh + edge, d)

                // Direction for sun highlight (az∈[-π, π], el∈[-π/2, π/2]).
                let az = (u - 0.5) * 2 * .pi
                let el = (.pi / 2) - theta
                let dir = simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
                let h = powf(max(0, simd_dot(dir, sunDir)), 24) // tight glossy lobe
                let cloudCol = simd_float3(repeating: 1.0) * (0.92 + 0.08 * h)

                let rgb = mix3(skyBase, cloudCol, t)
                let idx = (j * W + i) * 4
                out[idx + 0] = toByte(rgb.x)
                out[idx + 1] = toByte(rgb.y)
                out[idx + 2] = toByte(rgb.z)
                out[idx + 3] = 255
            }
        }

        return CumulusPixels(width: W, height: H, rgba: out)
    }
}
