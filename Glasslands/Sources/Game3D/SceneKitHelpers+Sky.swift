//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import UIKit
import CoreGraphics
import simd

enum SkyGen {
    static var defaultCoverage: Float = 0.34

    private struct Key: Hashable {
        let w: Int, h: Int
        let covQ: Int, softQ: Int
        let seed: UInt32
        let sunAzQ: Int, sunElQ: Int
    }

    private static var cache: [Key: UIImage] = [:]

    /// Generate a bright, white cumulus sky with distance perspective.
    /// The result is a 2:1 equirectangular texture that wraps horizontally (no seam),
    /// with uniform coverage up to the zenith (no top void) and no circular caps.
    static func skyWithCloudsImage(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = defaultCoverage,   // ~0.28–0.40 for “nice day”
        edgeSoftness: Float = 0.20,          // 0.15–0.28; higher = softer edges
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63
    ) -> UIImage {
        let W = max(256, width)
        let H = max(128, height)

        let key = Key(
            w: W, h: H,
            covQ: Int((coverage * 1000).rounded()),
            softQ: Int((edgeSoftness * 1000).rounded()),
            seed: seed,
            sunAzQ: Int((sunAzimuthDeg * 10).rounded()),
            sunElQ: Int((sunElevationDeg * 10).rounded())
        )
        if let img = cache[key] { return img }

        // Work at a modest density resolution and upsample implicitly during raster.
        let FW = max(256, W / 2)
        let FH = max(128, H / 2)

        // ---------------------------------------------------------------------
        // Density field built from clustered elliptical puffs with perspective.
        // ---------------------------------------------------------------------
        var field = [Float](repeating: 0, count: FW * FH)

        struct LCG {
            private var s: UInt32
            init(_ seed: UInt32) { s = seed != 0 ? seed : 1 }
            mutating func next() -> UInt32 { s = 1664525 &* s &+ 1013904223; return s }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
            mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
            mutating func norm(_ mu: Float, _ sigma: Float) -> Float {
                // Box-Muller
                let u1 = max(1e-6, unit())
                let u2 = unit()
                let r = sqrtf(-2.0 * logf(u1))
                let t = 2.0 * .pi * u2
                return mu + sigma * r * cosf(t)
            }
        }
        var rng = LCG(seed ^ 0xA51C_2C2D)

        // Perspective distribution: more/smaller clusters toward the horizon,
        // fewer/larger higher up, plus some guaranteed zenith content.
        let clusterCount = max(36, (FW * FH) / 24000)
        for _ in 0..<clusterCount {
            let u = rng.unit()
            let xC = u * Float(FW)

            // 70% of clusters nearer the horizon (lower part of texture),
            // 30% up top to keep the zenith lively.
            let v: Float = (rng.unit() < 0.70)
                ? rng.range(0.55, 0.90)
                : rng.range(0.12, 0.42)
            let yC = v * Float(FH)

            // Cluster parameters (bigger up top, smaller near horizon).
            let sizeBias = 0.55 + 0.45 * (1.0 - v)
            let baseAmp  = 0.95 + 0.35 * rng.unit()
            let puffCount = Int(clamp(Int(roundf(9 + 9 * sizeBias)), 8, 20))

            let dir = rng.range(-0.55, 0.55)
            let cth = cosf(dir), sth = sinf(dir)

            for _ in 0..<puffCount {
                let jx = rng.norm(0, 0.12) * sizeBias
                let jy = rng.norm(0, 0.10) * sizeBias
                let cx = xC + jx * Float(FW)
                let cy = yC + jy * Float(FH)

                // Ellipse radii (horizontal puffs).
                let base = (0.016 + 0.020 * rng.unit()) * sizeBias
                let rx = base * (1.30 + 0.70 * rng.unit()) * Float(FW)
                let ry = base * (0.85 + 0.45 * rng.unit()) * Float(FH)

                let amp = baseAmp * (0.80 + 0.35 * rng.unit())

                // Stamp only in a small neighbourhood; wrap horizontally.
                let ex = max(8.0, rx * 2.8)
                let ey = max(8.0, ry * 2.8)
                let xMin = Int(floorf(cx - ex)), xMax = Int(ceilf(cx + ex))
                let yMin = Int(floorf(cy - ey)), yMax = Int(ceilf(cy + ey))
                let y0 = max(0, yMin), y1 = min(FH - 1, yMax)
                if y0 > y1 { continue }

                for yy in y0...y1 {
                    let Y = (Float(yy) + 0.5) - cy
                    // Slightly heavier bottoms for cumulus character.
                    let bottom = smooth01(clampf((Y + 0.5 * ry) / (2.0 * ry), 0, 1))
                    let gravBias: Float = 1.0 + 0.22 * bottom

                    var xx = xMin
                    while xx <= xMax {
                        let xw0 = wrapIndex(xx, FW)          // wrapped write index
                        let X = (Float(xx) + 0.5) - cx

                        // Rotate into local puff frame.
                        let xr = (X * cth - Y * sth) / max(1e-4, rx)
                        let yr = (X * sth + Y * cth) / max(1e-4, ry)
                        let d2 = xr * xr + yr * yr

                        // Soft bell: (1 + k r^2)^-2 with small per-pixel k jitter.
                        let kBase: Float = 1.55 + 0.50 * rng.unit()
                        let shape = 1.0 / ((1.0 + kBase * d2) * (1.0 + kBase * d2))

                        field[yy * FW + xw0] += amp * shape * gravBias

                        // Mirror-write at x±W to enforce horizontal wrap (near bounds).
                        if xx < 0 || xx >= FW {
                            let xw1 = wrapIndex(xx < 0 ? xx + FW : xx - FW, FW)
                            field[yy * FW + xw1] += amp * shape * gravBias
                        }
                        xx += 1
                    }
                }
            }
        }

        // Normalise and soften.
        var maxVal: Float = 0
        for v in field where v.isFinite && v > maxVal { maxVal = v }
        let invMax = maxVal > 0 ? (1.0 / maxVal) : 1.0
        for i in 0..<(FW*FH) {
            var t = field[i] * invMax
            t = max(0, t)
            // Gentle softening curve (≈ x^1.2 without pow).
            t = t * (0.70 + 0.30 * t)
            field[i] = t
        }

        // Coverage → threshold, then edge softness.
        let edge = clampf(edgeSoftness, 0.10, 0.35)
        let thresh = clampf(0.58 - 0.36 * coverage, 0.32, 0.68)

        // ---------------------------------------------------------------------
        // Rasterise to RGBA with lighting that keeps clouds bright white.
        // ---------------------------------------------------------------------
        var out = [UInt8](repeating: 0, count: W * H * 4)

        // Sun vector.
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        var sunDir = simd_float3(sinf(sunAz) * cosf(sunEl), sinf(sunEl), cosf(sunAz) * cosf(sunEl))
        sunDir = simd_normalize(sunDir)

        // Sky palette (top → horizon).
        let SKY_TOP = simd_float3(0.30, 0.56, 0.96)
        let SKY_MID = simd_float3(0.56, 0.74, 0.96)
        let SKY_BOT = simd_float3(0.88, 0.93, 0.99)

        // Helpers to sample the density field with bilinear filtering.
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

        // Finite differences for a pseudo-normal from density.
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
            let v = (Float(j) + 0.5) * invH
            // Clean blue gradient with a pale horizon.
            var sky = mix3(SKY_TOP, SKY_MID, v)
            sky = mix3(sky, SKY_BOT, smoothstep(0.62, 1.00, v))

            for i in 0..<W {
                let u = (Float(i) + 0.5) * invW

                // Lat-long mapping: UV to elevation distribution.
                let maskSrc = sampleField(u: u, v: v)
                let mask = smoothstep(thresh - edge, thresh + edge, maskSrc)

                // Pseudo-normal from density gradients.
                let (gx, gy) = gradField(u: u, v: v)
                var n = simd_float3(-gx * 1.4, 1.0, -gy * 1.0)
                n = simd_normalize(n)

                // Keep clouds white; add gentle highlight on lit sides.
                let ndotl = max(0, simd_dot(n, sunDir))
                var shade: Float = 0.92 + 0.18 * ndotl

                // AO-ish interior darkening so puffs read as volumes.
                let ao = 0.18 * powf(smoothstep(0.55, 0.99, mask), 1.1)
                shade = max(0.86, min(1.0, shade * (1.0 - ao)))

                // Very subtle bright rim on edges (no blue tint).
                let edgeAmt = 0.10 * smoothstep(0.35, 0.95, 1.0 - mask) * (0.6 + 0.4 * ndotl)
                let cloud = simd_clamp(simd_float3(repeating: shade) + simd_float3(0.95, 0.97, 1.00) * edgeAmt,
                                       simd_float3(repeating: 0), simd_float3(repeating: 1))

                let rgb = sky * (1.0 - mask) + cloud * mask

                let idx = (j * W + i) * 4
                out[idx + 0] = toByte(rgb.x)
                out[idx + 1] = toByte(rgb.y)
                out[idx + 2] = toByte(rgb.z)
                out[idx + 3] = 255
            }
        }

        // Enforce exact horizontal wrap (copy first column to last).
        for j in 0..<H {
            let a = (j * W + 0) * 4
            let b = (j * W + (W - 1)) * 4
            out[b + 0] = out[a + 0]
            out[b + 1] = out[a + 1]
            out[b + 2] = out[a + 2]
            out[b + 3] = out[a + 3]
        }

        let img = rgba8ToUIImage(pixels: out, width: W, height: H)
        cache[key] = img
        return img
    }

    // MARK: - Small utilities (local)

    @inline(__always) private static func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, x)) }
    @inline(__always) private static func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { x.isFinite ? min(hi, max(lo, x)) : lo }
    @inline(__always) private static func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
    @inline(__always) private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let d = e1 - e0; return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d) }
    @inline(__always) private static func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
    @inline(__always) private static func toByte(_ f: Float) -> UInt8 { UInt8(clampf(f, 0, 1) * 255.0 + 0.5) }
    @inline(__always) private static func safeFloorInt(_ x: Float) -> Int { let y = floorf(x); return y >= Float(Int.max) ? Int.max : (y <= Float(Int.min) ? Int.min : Int(y)) }
    @inline(__always) private static func safeIndex(_ i: Int, _ lo: Int, _ hi: Int) -> Int { (i < lo) ? lo : (i > hi ? hi : i) }
    @inline(__always) private static func wrapIndex(_ i: Int, _ n: Int) -> Int { let m = i % n; return m < 0 ? m + n : m }

    private static func rgba8ToUIImage(pixels: [UInt8], width: Int, height: Int) -> UIImage {
        let bpr = width * 4
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let img = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: img)
    }
}
