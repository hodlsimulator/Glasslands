//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Soft cumulus puff sprites (premultiplied alpha).
//  Ensures a *hard* transparent 2‑pixel border so clampToBorder works perfectly.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {

    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    /// Builds a small atlas of puff images (sRGB, premultiplied alpha).
    static func makeAtlas(
        size: Int = 512,
        seed: UInt32 = 0xC10D5,
        count: Int = 4
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(256, size)

        let images: [UIImage] = await MainActor.run {
            let c: UInt32 = 0x9E37_79B9 // Weyl-like increment
            return (0..<n).map { i in
                let k = UInt32(i &+ 1)
                let imgSeed = seed &+ (c &* k)  // all UInt32 math (no traps)
                return buildImage(s, seed: imgSeed)
            }
        }
        return Atlas(images: images, size: s)
    }

    // MARK: - Private (image synthesis)

    @inline(__always)
    private static func hash2(_ x: Int32, _ y: Int32) -> Float {
        let n = sinf(Float(x) * 127.1 + Float(y) * 311.7) * 43758.5453
        return n - floorf(n)
    }

    @inline(__always)
    private static func vnoise(_ x: Float, _ y: Float) -> Float {
        let ix = floorf(x), iy = floorf(y)
        let fx = x - ix, fy = y - iy
        let a = hash2(Int32(ix), Int32(iy))
        let b = hash2(Int32(ix + 1), Int32(iy))
        let c = hash2(Int32(ix), Int32(iy + 1))
        let d = hash2(Int32(ix + 1), Int32(iy + 1))
        let u = fx*fx*(3 - 2*fx)
        let v = fy*fy*(3 - 2*fy)
        return a*(1-u)*(1-v) + b*u*(1-v) + c*(1-u)*v + d*u*v
    }

    @inline(__always)
    private static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let res = -log(exp(-k*a) + exp(-k*b)) / k
        return res.isFinite ? res : min(a, b)
    }

    @MainActor
    private static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let stride = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        var state = seed == 0 ? 1 : Int(seed)
        @inline(__always) func frand() -> Float {
            state = 1664525 &* state &+ 1013904223
            return Float((state >> 8) & 0xFFFFFF) * (1.0 / 16777216.0)
        }

        struct Ball { var c: simd_float2; var r: Float }
        var balls: [Ball] = []

        // Core + lobes → cauliflower silhouette
        let coreR: Float = 0.29 + frand() * 0.05
        balls.append(Ball(c: simd_float2(0.50, 0.53 + frand()*0.03), r: coreR))

        let capN = 4 + Int(frand() * 3)
        for _ in 0..<capN {
            let a = Float.pi * (0.22 + 0.58 * frand())
            let d = 0.16 + 0.22 * frand()
            let r = 0.12 + 0.10 * frand()
            let cx = 0.5 + cosf(a) * d
            let cy = 0.56 + sinf(a) * d
            balls.append(Ball(c: simd_float2(cx, cy), r: r))
        }

        let skirtN = 2 + Int(frand() * 2)
        for _ in 0..<skirtN {
            let a = Float.pi * (0.95 + 0.10 * frand())
            let d = 0.22 + 0.32 * frand()
            let r = 0.10 + 0.10 * frand()
            let cx = 0.5 + cosf(a) * d
            let cy = 0.50 + sinf(a) * d
            balls.append(Ball(c: simd_float2(cx, cy), r: r))
        }

        // Union SDF
        let kBlend: Float = 12.0
        @inline(__always)
        func sdf(_ p: simd_float2) -> Float {
            var d: Float = .greatestFiniteMagnitude
            for b in balls {
                let l = length(p - b.c) - b.r
                d = smin(d, l, kBlend)
            }
            return d
        }

        // Edge softness and apron
        let edgeSoft: Float = 0.055 + 0.015 * frand()

        for y in 0..<H {
            let fy = (Float(y) + 0.5) / Float(H)
            for x in 0..<W {
                let fx = (Float(x) + 0.5) / Float(W)

                // Radial apron to zero (transparent) beyond unit circle
                let dx = (fx - 0.5) / 0.5
                let dy = (fy - 0.5) / 0.5
                let r = sqrtf(dx*dx + dy*dy)
                if r >= 1.0 {
                    let o = (y * W + x) * 4
                    buf[o + 0] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
                    continue
                }

                // Density 0..1 (inside → 1)
                let d = sdf(simd_float2(fx, fy))
                var a = 1.0 - smoothstep(0.0, edgeSoft, d)
                a = max(0, min(1, a))

                // Gentle top‑light using SDF gradient (cheap normal)
                let eps: Float = 2.0 / Float(W)
                let nx = sdf(simd_float2(fx + eps, fy)) - sdf(simd_float2(fx - eps, fy))
                let ny = sdf(simd_float2(fx, fy + eps)) - sdf(simd_float2(fx, fy - eps))
                let L = simd_normalize(simd_float2(0.0, -1.0)) // from top
                var shade = max(0.0, min(1.0, (-(nx*L.x + ny*L.y)) * 0.6 + 0.92))
                shade = shade * (0.92 + 0.08 * a)

                // Premultiplied alpha RGB
                let c = min(1.0, a * shade)
                let o = (y * W + x) * 4
                buf[o + 0] = UInt8(c * 255.0 + 0.5)
                buf[o + 1] = UInt8(c * 255.0 + 0.5)
                buf[o + 2] = UInt8(c * 255.0 + 0.5)
                buf[o + 3] = UInt8(a * 255.0 + 0.5)
            }
        }

        // Force a *hard* transparent 2‑pixel frame (prevents any edge pickup).
        if W >= 4 && H >= 4 {
            for y in 0..<H {
                for x in 0..<W {
                    if x < 2 || x >= W-2 || y < 2 || y >= H-2 {
                        let o = (y * W + x) * 4
                        buf[o + 0] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
                    }
                }
            }
        }

        let data = CFDataCreate(nil, buf, buf.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!

        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    @inline(__always)
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        if x <= a { return 0 }
        if x >= b { return 1 }
        let t = (x - a) / (b - a)
        return t * t * (3 - 2 * t)
    }
}
