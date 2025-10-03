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
    static var defaultCoverage: Float = 0.0  // 0 → blue sky only (clouds disabled by default)

    private struct Key: Hashable {
        let w: Int, h: Int
        let covQ: Int, thickQ: Int
        let seed: UInt32
        let sunAzQ: Int, sunElQ: Int
    }

    private static var cache: [Key: UIImage] = [:]

    static func skyWithCloudsImage(
        width: Int = 2048,
        height: Int = 1024,
        coverage: Float = defaultCoverage,   // 0.0–0.35 typical; 0 disables clouds
        thickness: Float = 0.12,             // edge softness 0.05–0.25
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)

        // Quantise to stabilise cache keys.
        let key = Key(
            w: W, h: H,
            covQ: Int((coverage * 1000).rounded()),
            thickQ: Int((thickness * 1000).rounded()),
            seed: seed,
            sunAzQ: Int((sunAzimuthDeg * 10).rounded()),
            sunElQ: Int((sunElevationDeg * 10).rounded())
        )
        if let img = cache[key] { return img }

        // Pixel buffer (RGBA8).
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

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

        // Sun vector (used subtly to lift the gradient).
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Sky gradient colours (natural midday).
        let SKY_TOP = simd_float3(0.22, 0.50, 0.92)
        let SKY_MID = simd_float3(0.50, 0.73, 0.95)
        let SKY_BOT = simd_float3(0.86, 0.93, 0.98)

        // ----- Gradient-only path (fast, no clouds) -----
        if coverage <= 0 {
            for j in 0..<H {
                let v = Float(j) / Float(H - 1)
                let tLow = smooth01(v * 1.1)
                let midBlend = smoothstep(0.35, 0.75, v)
                let base = mix3(mix3(SKY_BOT, SKY_MID, tLow), SKY_TOP, midBlend)

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

        // ----- Cloud field (deterministic, cheap FBM) -----
        @inline(__always) func h2(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
            var h = UInt32(bitPattern: x) &* 374761393
            h &+= UInt32(bitPattern: y) &* 668265263
            h &+= s &* 2246822519 &+ 0x9E3779B9
            h ^= h >> 13
            h &*= 1274126177
            return h
        }
        @inline(__always) func rnd(_ x: Int32, _ y: Int32, _ s: UInt32) -> Float {
            Float(h2(x, y, s) & 0x00FF_FFFF) * (1.0 / 16_777_215.0)
        }
        @inline(__always) func valueNoise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
            let xi = floorf(x), yi = floorf(y)
            let tx = x - xi, ty = y - yi
            let x0 = Int32(xi), y0 = Int32(yi)
            let a = rnd(x0, y0, s)
            let b = rnd(x0 + 1, y0, s)
            let c = rnd(x0, y0 + 1, s)
            let d = rnd(x0 + 1, y0 + 1, s)
            let u = smooth01(tx), v = smooth01(ty)
            let ab = a + (b - a) * u
            let cd = c + (d - c) * u
            return ab + (cd - ab) * v
        }
        @inline(__always) func fbm(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
            var f: Float = 0
            var amp: Float = 0.5
            var freq: Float = 1
            for o in 0..<5 {
                f += amp * valueNoise(x * freq, y * freq, s &+ UInt32(1299721 * (o + 1)))
                freq *= 2
                amp *= 0.55
            }
            return f
        }

        let scale: Float = 1.7
        var fmin: Float = 1, fmax: Float = 0
        var field = [Float](repeating: 0, count: W * H)

        for j in 0..<H {
            let v = Float(j) / Float(H)
            for i in 0..<W {
                let u = Float(i) / Float(W)

                // Equirectangular to direction; bias more coverage near horizon.
                let theta = (u - 0.5) * 2 * .pi
                let phi = v * .pi
                var dir = simd_float3(sinf(theta) * sinf(phi), cosf(phi), cosf(theta) * sinf(phi))

                // Mild warp to split large masses.
                let w = fbm(u * 2.0, v * 1.2, seed &+ 991)
                dir.x += (w - 0.5) * 0.08
                dir.z += (w - 0.5) * 0.05

                // Project to 2D plane for sampling.
                let px = (atan2f(dir.x, dir.z) / (2 * .pi) + 0.5) * scale * 3.0
                let py = (acosf(clampf(dir.y, -1, 1)) / .pi) * scale * 1.6

                var f = fbm(px, py, seed)
                fmin = min(fmin, f)
                fmax = max(fmax, f)
                field[j * W + i] = f
            }
        }
        let span: Float = max(1e-6, fmax - fmin)
        for k in 0..<(W * H) { field[k] = (field[k] - fmin) / span }

        let tEdge = clampf(thickness, 0.01, 0.5)
        let baseCut: Float = clampf(0.60 - coverage * 0.35, 0.25, 0.65)

        // Zenith cap to prevent white-out near the very top.
        let capStart: Float = 0.975
        let capEnd:   Float = 0.992

        for j in 0..<H {
            let v = Float(j) / Float(H - 1)

            // Vertical gradient.
            let tLow = smooth01(v * 1.1)
            let midBlend = smoothstep(0.35, 0.75, v)
            var base = mix3(mix3(SKY_BOT, SKY_MID, tLow), SKY_TOP, midBlend)

            // Gentle brightening toward the sun.
            do {
                let phi = v * .pi
                let dir = simd_float3(0, cosf(phi), 0)
                let sunLift = max(0, simd_dot(dir, sunDir))
                let lift = sunLift * 0.03
                base = base + simd_float3(repeating: lift)
            }

            for i in 0..<W {
                let idx = (j * W + i) * 4
                var c = base

                var f = field[j * W + i]

                // Stronger attenuation near zenith to kill the “white cap”.
                if v <= capEnd {
                    let cap = 1 - smoothstep(capStart, capEnd, v)
                    // Avoid simd's generic mix overloads; just lerp to zero explicitly:
                    f *= (1 - cap)
                }

                // Soft thresholding for cloud alpha.
                let a = smoothstep(baseCut, baseCut + tEdge, f) * coverage * 1.6
                if a > 0 {
                    // Slightly darker cloud cores.
                    let cloud = simd_float3(1, 1, 1) * (0.92 - (f * 0.15))
                    c = mix3(c, cloud, clampf(a, 0, 1))
                }

                pixels[idx + 0] = toByte(c.x)
                pixels[idx + 1] = toByte(c.y)
                pixels[idx + 2] = toByte(c.z)
                pixels[idx + 3] = 255
            }
        }

        let img = imageFromRGBA(pixels: pixels, width: W, height: H)
        cache[key] = img
        return img
    }

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
