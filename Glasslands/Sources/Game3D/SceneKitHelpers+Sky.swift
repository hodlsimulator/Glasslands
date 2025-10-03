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
        coverage: Float = 0.20,   // 0 → gradient only, 0.1–0.3 typical
        thickness: Float = 0.12,  // edge softness in [0.05, 0.25]
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
            min(hi, max(lo, x.isFinite ? x : lo))
        }
        @inline(__always) func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
        @inline(__always) func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d)
        }
        @inline(__always) func toByte(_ f: Float) -> UInt8 { UInt8(clampf(f, 0, 1) * 255.0 + 0.5) }

        // Sun vector
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Sky gradient colours
        let SKY_TOP = simd_float3(0.22, 0.50, 0.92)
        let SKY_MID = simd_float3(0.50, 0.73, 0.95)
        let SKY_BOT = simd_float3(0.86, 0.93, 0.98)

        // ----- Gradient-only early return (fast path) -----
        if coverage <= 0 {
            for j in 0..<H {
                let v = (Float(j) + 0.5) / Float(H)
                for i in 0..<W {
                    let u = (Float(i) + 0.5) / Float(W)
                    let az = u * (.pi * 2)
                    let el = (1 - v) * .pi - (.pi / 2)
                    let dir = simd_normalize(simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el)))

                    let upY = dir.y
                    let t1 = smoothstep(-0.15, 0.55, upY)
                    let base = mix3(SKY_BOT, SKY_MID, t1)
                    let t2 = smoothstep(0.25, 0.95, upY)
                    var sky = mix3(base, SKY_TOP, t2)

                    let nd = max(0.0 as Float, simd_dot(dir, sunDir))
                    let halo = powf(nd, 8) * 0.08 + powf(nd, 32) * 0.05
                    sky = sky + simd_float3(repeating: halo)

                    let idx = j * bpr + i * 4
                    pixels[idx + 0] = toByte(sky.x)
                    pixels[idx + 1] = toByte(sky.y)
                    pixels[idx + 2] = toByte(sky.z)
                    pixels[idx + 3] = 255
                }
            }
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            var cg: CGImage?
            pixels.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                if let ctx = CGContext(data: base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bitmapInfo) {
                    cg = ctx.makeImage()
                }
            }
            return cg.map { UIImage(cgImage: $0, scale: 1, orientation: .up) } ?? UIImage()
        }

        // ----- fBm value-noise field (low-res) -----
        let gW = max(64, W / 3)
        let gH = max(32, H / 3)
        var field = [Float](repeating: 0, count: gW * gH)

        @inline(__always) func h2(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
            var h = UInt32(bitPattern: x) &* 374761393
            h &+= UInt32(bitPattern: y) &* 668265263
            h &+= s &* 2246822519 &+ 0x9E3779B9
            h ^= h >> 13; h &*= 1274126177
            return h
        }
        @inline(__always) func rnd(_ x: Int32, _ y: Int32, _ s: UInt32) -> Float {
            Float(h2(x, y, s) & 0x00FF_FFFF) * (1.0 / 16_777_215.0)
        }
        @inline(__always) func valueNoise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
            let xi = floorf(x), yi = floorf(y)
            let tx = x - xi, ty = y - yi
            let x0 = Int32(xi), y0 = Int32(yi)
            let a = rnd(x0,     y0,     s)
            let b = rnd(x0 + 1, y0,     s)
            let c = rnd(x0,     y0 + 1, s)
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

        var fmin: Float = 1, fmax: Float = 0
        for j in 0..<gH {
            let v = Float(j) / Float(gH)
            for i in 0..<gW {
                let u = Float(i) / Float(gW)
                var f = fbm(u * 5.0, v * 5.0, seed)
                f = powf(f, 1.15)
                field[j * gW + i] = f
                if f < fmin { fmin = f }
                if f > fmax { fmax = f }
            }
        }
        let invSpan: Float = (fmax > fmin) ? 1.0 / (fmax - fmin) : 1
        for i in 0..<field.count { field[i] = (field[i] - fmin) * invSpan }

        // Histogram → quantile threshold for exact coverage
        var hist = [Int](repeating: 0, count: 256)
        for v in field { hist[max(0, min(255, Int(v * 255)))] += 1 }
        let total = field.count
        let targetBelow = Int(Float(total) * (1 - clampf(coverage, 0, 1)))
        var cum = 0, bin = 0
        while bin < 256 && cum < targetBelow { cum += hist[bin]; bin += 1 }
        let T = clampf(Float(bin) / 255.0, 0.0, 1.0)
        let T1 = clampf(T + max(0.01, thickness), 0, 1)

        @inline(__always) func sampleField(u: Float, v: Float) -> Float {
            let uc = clampf(u, 0, 0.99999)
            let vc = clampf(v, 0, 0.99999)
            let xf = uc * Float(gW) - 0.5
            let yf = vc * Float(gH) - 0.5
            let xi = Int(floorf(xf)), yi = Int(floorf(yf))
            let tx = xf - floorf(xf), ty = yf - floorf(yf)
            let x0 = max(0, min(gW - 1, xi)), x1 = max(0, min(gW - 1, xi + 1))
            let y0 = max(0, min(gH - 1, yi)), y1 = max(0, min(gH - 1, yi + 1))
            let i00 = y0 * gW + x0, i10 = y0 * gW + x1
            let i01 = y1 * gW + x0, i11 = y1 * gW + x1
            let a = field[i00], b = field[i10], c = field[i01], d = field[i11]
            let ab = a + (b - a) * tx
            let cd = c + (d - c) * tx
            let v2 = ab + (cd - ab) * ty
            return v2.isFinite ? v2 : 0
        }

        // Render equirect texture
        let capStart: Float = 0.975, capEnd: Float = 0.992
        for j in 0..<H {
            let v = (Float(j) + 0.5) / Float(H)
            for i in 0..<W {
                let u = (Float(i) + 0.5) / Float(W)

                let az = u * (.pi * 2)
                let el = (1 - v) * .pi - (.pi / 2)
                let dir = simd_normalize(simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el)))
                let upY = dir.y

                let t1 = smoothstep(-0.15, 0.55, upY)
                let base = mix3(SKY_BOT, SKY_MID, t1)
                let t2 = smoothstep(0.25, 0.95, upY)
                let sky = mix3(base, SKY_TOP, t2)

                let raw = sampleField(u: u, v: v)
                var a = smoothstep(T, T1, raw)

                var grav = 1 - clampf(upY, 0, 1)
                grav = grav * (0.65 + 0.35 * grav)
                a *= (0.92 + 0.08 * grav)

                let tFade = smoothstep(capStart, capEnd, upY)
                a *= (1.0 - 0.35 * tFade)

                let nd = max(0.0 as Float, simd_dot(dir, sunDir))
                let nd2 = nd * nd, nd4 = nd2 * nd2, nd8 = nd4 * nd4
                let silver = nd4 * 0.18 + nd8 * 0.28

                let cloudBase: Float = 0.78
                let cloud = simd_float3(repeating: clampf(cloudBase + silver, 0, 1))

                let rgb = mix3(sky, cloud, a)

                let idx = j * bpr + i * 4
                pixels[idx + 0] = toByte(rgb.x)
                pixels[idx + 1] = toByte(rgb.y)
                pixels[idx + 2] = toByte(rgb.z)
                pixels[idx + 3] = 255
            }
        }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var cg: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let ctx = CGContext(data: base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bitmapInfo) {
                cg = ctx.makeImage()
            }
        }
        return cg.map { UIImage(cgImage: $0, scale: 1, orientation: .up) } ?? UIImage()
    }
}
