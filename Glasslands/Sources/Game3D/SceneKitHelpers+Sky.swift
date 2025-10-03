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

/// Equirectangular sky with natural cumulus using deterministic soft “cloud blobs”.
/// No pow/exp/log in inner loops; guarded Float→Int; clamps everywhere.
enum SkyGen {
    // Default only if a caller does not pass coverage explicitly.
    // 0.26–0.34 are good day sky ranges.
    static var defaultCoverage: Float = 0.30

    private struct Key: Hashable {
        let w: Int, h: Int
        let covQ: Int, thickQ: Int
        let seed: UInt32
        let sunAzQ: Int, sunElQ: Int
    }

    private static var cache: [Key: UIImage] = [:]

    /// Generates a single sky map image (gradient + clouds). Cached by parameters.
    static func skyWithCloudsImage(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = defaultCoverage,     // lower → fuller clouds (try 0.26–0.34)
        thickness: Float = 0.44,               // higher → softer edges (0.38–0.65)
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)

        let key = Key(
            w: W, h: H,
            covQ: Int((coverage * 1000).rounded()),
            thickQ: Int((thickness * 1000).rounded()),
            seed: seed,
            sunAzQ: Int((sunAzimuthDeg * 10).rounded()),
            sunElQ: Int((sunElevationDeg * 10).rounded())
        )
        if let img = cache[key] { return img }

        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        // --- tiny helpers ----------------------------------------------------
        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
            x.isFinite ? min(hi, max(lo, x)) : lo
        }
        @inline(__always) func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 {
            a + (b - a) * t
        }
        @inline(__always) func smooth01(_ x: Float) -> Float {
            let t = clampf(x, 0, 1); return t * t * (3 - 2 * t)
        }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d)
        }
        @inline(__always) func toByte(_ f: Float) -> UInt8 {
            UInt8(clampf(f, 0, 1) * 255.0 + 0.5)
        }
        @inline(__always) func safeFloorInt(_ x: Float) -> Int {
            guard x.isFinite else { return 0 }
            let y = floorf(x)
            if y >= Float(Int.max) { return Int.max }
            if y <= Float(Int.min) { return Int.min }
            return Int(y)
        }
        @inline(__always) func safeIndex(_ i: Int, _ lo: Int, _ hi: Int) -> Int {
            (i < lo) ? lo : (i > hi ? hi : i)
        }

        // Sun vector for subtle rim lighting.
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Lighter, “whiter” blue gradient (top→horizon).
        let SKY_TOP = simd_float3(0.50, 0.74, 0.92)
        let SKY_MID = simd_float3(0.70, 0.86, 0.95)
        let SKY_BOT = simd_float3(0.86, 0.93, 0.98)

        // Gradient-only early out.
        if coverage <= 0 {
            for j in 0..<H {
                let v = Float(j) / Float(H - 1)  // 0 = zenith
                let t = smooth01(v)
                let a = mix3(SKY_TOP, SKY_MID, t)
                let b = mix3(SKY_MID, SKY_BOT, t)
                let base = mix3(a, b, t)
                for i in 0..<W {
                    let idx = (j * W + i) * 4
                    pixels[idx + 0] = toByte(base.x)
                    pixels[idx + 1] = toByte(base.y)
                    pixels[idx + 2] = toByte(base.z)
                    pixels[idx + 3] = 255
                }
            }
            let img = imageFromRGBA(pixels: pixels, width: W, height: H)
            cache[key] = img
            return img
        }

        // --- “Soft cloud blobs” field (low-res grid → upsample) --------------
        // Deterministic RNG (top 24 bits → exact in Float).
        struct LCG {
            private var state: UInt32
            init(seed: UInt32) { self.state = seed &* 1664525 &+ 1013904223 }
            mutating func next() -> UInt32 { state = 1664525 &* state &+ 1013904223; return state }
            mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) } // [0,1)
            mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
        }
        var rng = LCG(seed: seed != 0 ? seed : 1)

        let gW = max(64, W / 3)
        let gH = max(32, H / 3)
        var field = [Float](repeating: 0, count: gW * gH)

        // Puff count scales with grid size and (inversely) with coverage.
        let baseCount = max(60, (gW * gH) / 80)
        let puffCount = Int(Float(baseCount) * (0.34 / max(0.10, coverage)))

        // Very soft zenith cap to keep overhead blue (expressed in upY space).
        let capStart: Float = 0.975   // start near zenith (~12° from top)
        let capEnd:   Float = 0.992   // mostly gone by ~7°

        // Sprinkle elliptical puffs with horizontal bias.
        for _ in 0..<puffCount {
            // Random equirectangular (u,v) → direction.
            let u = rng.unit()
            let v = rng.unit()
            let theta = (u - 0.5) * 2 * .pi
            let phi = v * .pi
            let dir = simd_float3(sinf(theta) * sinf(phi), cosf(phi), cosf(theta) * sinf(phi))
            let upY = dir.y

            // Base radius in normalized grid units.
            let rBase = 0.060 * (0.85 + 0.30 * rng.unit())
            let rx = rBase * (1.30 + 0.40 * rng.unit()) // 1.30…1.70 × rBase
            let ry = rBase * (0.55 + 0.25 * rng.unit()) // 0.55…0.80 × rBase

            // Orientation: near horizontal with ±10° jitter.
            let maxJitter: Float = .pi * 0.055
            let ang = rng.range(-maxJitter, maxJitter)
            let ca = cosf(ang), sa = sinf(ang)

            // Amplitude, slightly stronger toward horizon.
            let amp = 0.8 + 0.4 * rng.unit()
            let horizonBoost: Float = 0.20 * (1 - clampf(upY, 0, 1))

            // Grid footprint (ellipse), expanded sampling bounds.
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

            // Soft cap near zenith — retain ~60% at exact zenith.
            let tFade = smoothstep(capStart, capEnd, upY)
            let tCap = 1.0 - 0.40 * tFade

            if x0 > x1 || y0 > y1 { continue }

            for gy in y0...y1 {
                let yy = (Float(gy) + 0.5) - cy
                // Gravity bias inside the puff (heavier below centre).
                let gravBias = 1.0 + 0.22 * smoothstep(0, sy * 0.8, max(0, yy))

                for gx in x0...x1 {
                    let xx = (Float(gx) + 0.5) - cx

                    // Rotate into puff’s local frame.
                    let xr = (xx * ca - yy * sa) / max(1e-4, sx)
                    let yr = (xx * sa + yy * ca) / max(1e-4, sy)
                    let d2 = xr * xr + yr * yr

                    // Smooth bell without exp/pow: (1 + k*d^2)^-2
                    let k: Float = 1.75
                    let shape = 1.0 / ((1.0 + k * d2) * (1.0 + k * d2))

                    let add = (amp + horizonBoost) * shape * tCap * gravBias
                    let idx = gy * gW + gx
                    if add.isFinite { field[idx] += add }
                }
            }
        }

        // Normalise to 0..1 and gently “raise” (~x^1.2 without pow).
        var fmax: Float = 0
        for v in field where v.isFinite && v > fmax { fmax = v }
        let invMax: Float = fmax > 0 ? (1.0 / fmax) : 1.0
        for i in 0..<(gW * gH) {
            var t = field[i] * invMax
            t = max(0, t)
            t = t * (0.70 + 0.30 * t) // shallow billow
            field[i] = t
        }

        // Hash-based jitter per pixel (stable; no RNG in the hot loop).
        @inline(__always) func h2(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
            var h = UInt32(bitPattern: x) &* 374761393
            h &+= UInt32(bitPattern: y) &* 668265263
            h &+= s &* 2246822519 &+ 0x9E3779B9
            h ^= h >> 13
            h &*= 1274126177
            return h
        }

        // Bilinear sampler from the low-res field.
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

        // --- Final render (gradient + thresholded clouds) --------------------
        let thick = max(0.001, thickness)
        for j in 0..<H {
            // v: 0 = zenith (top), 1 = horizon (bottom).
            let v = Float(j) / Float(H - 1)
            let t = smooth01(v)

            // Gradient base.
            var sky = mix3(mix3(SKY_TOP, SKY_MID, t), mix3(SKY_MID, SKY_BOT, t), t)

            // Mild directional brightening near the sun (haze cue).
            do {
                let phi = v * .pi
                let dir = simd_float3(0, cosf(phi), 0)
                let sunLift = max(0, simd_dot(dir, sunDir))
                sky += simd_float3(repeating: sunLift * 0.010)
            }

            for i in 0..<W {
                let u = Float(i) / Float(W - 1)
                let theta = (u - 0.5) * 2 * .pi
                let phi = v * .pi
                let dir = simd_float3(sinf(theta) * sinf(phi), cosf(phi), cosf(theta) * sinf(phi))
                let upY = clampf(dir.y, 0, 1)

                // Stable per-pixel jitter in [-0.02, 0.02] to break banding.
                let jitterBits = h2(Int32(i), Int32(j), seed &+ 0xBEEF_CAFE)
                let jitter = (Float(jitterBits & 0xFFFF) / 65535.0 - 0.5) * 0.04

                // Gravity bias + horizon/zenith fades.
                var grav = 1 - upY
                grav = grav * (0.65 + 0.35 * grav)

                let baseThr = clampf(coverage - 0.06 * grav, 0, 1)
                let billow = sampleField(u: u, v: v)
                var a = smoothstep(baseThr + jitter, baseThr + jitter + thick, billow)

                // Slightly higher alpha near horizon (flatter clouds look denser).
                let flat = smoothstep(-0.10, 0.40, -dir.y)
                a *= (0.90 + 0.10 * flat)

                // Same soft zenith cap as field.
                let tFade = smoothstep(capStart, capEnd, upY)
                let tCap = 1.0 - 0.40 * tFade
                a *= clampf((upY + 0.20) * 1.4, 0, 1) * tCap

                // Subtle “silver lining” with integer powers only.
                let nd = max(0.0 as Float, simd_dot(simd_normalize(dir), sunDir))
                let nd2 = nd * nd, nd4 = nd2 * nd2, nd8 = nd4 * nd4
                let nd16 = nd8 * nd8, nd12 = nd8 * nd4, nd28 = nd16 * nd8 * nd4
                let silver = nd12 * 0.45 + nd28 * 0.35

                let cloud = simd_float3(repeating: 0.88 + 0.25 * silver)
                let rgb = mix3(sky, cloud, a)

                let idx = (j * W + i) * 4
                pixels[idx + 0] = toByte(rgb.x)
                pixels[idx + 1] = toByte(rgb.y)
                pixels[idx + 2] = toByte(rgb.z)
                pixels[idx + 3] = 255
            }
        }

        let img = imageFromRGBA(pixels: pixels, width: W, height: H)
        cache[key] = img
        return img
    }

    // --- image packer --------------------------------------------------------
    private static func imageFromRGBA(pixels: [UInt8], width: Int, height: Int) -> UIImage {
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
