//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Soft cumulus “puff” sprites (premultiplied alpha).
//  Silhouettes come from a small metaball SDF. Very light vertical tint and
//  micro-variation avoid banding. A hard transparent 2-px frame keeps sampling
//  clamp/mip safe.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {

    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    @MainActor
    static func makeAtlas(
        size: Int = 512,
        seed: UInt32 = 0xC10D5,
        count: Int = 6
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(256, size)

        var rng = seed &+ 0x9E37_79B9
        func nextSeed() -> UInt32 { rng = rng &* 1664525 &+ 1013904223; return rng }

        let images: [UIImage] = (0..<n).map { _ in
            buildImage(s, seed: nextSeed())
        }

        return Atlas(images: images, size: s)
    }

    @inline(__always)
    private static func smooth01(_ x: Float) -> Float {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let res = -log(exp(-k * a) + exp(-k * b)) / k
        return res.isFinite ? res : min(a, b)
    }

    @inline(__always)
    private static func hash2(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374_761_393
        h &+= UInt32(bitPattern: y) &* 668_265_263
        h ^= h >> 13
        h &*= 1_274_126_177
        return Float(h & 0x00FF_FFFF) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private static func vnoise(_ x: Float, _ y: Float) -> Float {
        let ix = floorf(x), iy = floorf(y)
        let fx = x - ix, fy = y - iy
        let a = hash2(Int32(ix), Int32(iy))
        let b = hash2(Int32(ix + 1), Int32(iy))
        let c = hash2(Int32(ix), Int32(iy + 1))
        let d = hash2(Int32(ix + 1), Int32(iy + 1))
        let u = fx * fx * (3 - 2 * fx)
        let v = fy * fy * (3 - 2 * fy)
        return a*(1-u)*(1-v) + b*u*(1-v) + c*(1-u)*v + d*u*v
    }

    @MainActor
    private static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let stride = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        var state = (seed == 0) ? 1 : Int(seed)
        @inline(__always) func frand() -> Float {
            state = 1664525 &* state &+ 1013904223
            return Float((state >> 8) & 0xFFFFFF) * (1.0 / 16_777_216.0)
        }

        struct Ball { var c: simd_float2; var r: Float }
        var balls: [Ball] = []

        let coreR: Float = 0.30 + frand() * 0.05
        balls.append(Ball(c: simd_float2(0.50, 0.53 + frand()*0.03), r: coreR))

        let capN = 4 + Int(frand() * 3)
        for _ in 0..<capN {
            let a = (frand() * 0.9 - 0.45) * .pi
            let d: Float = 0.20 + frand() * 0.20
            let r: Float = coreR * (0.70 + frand() * 0.25)
            let c = simd_float2(0.50 + cosf(a) * d, 0.52 + sinf(a) * (d * 0.82) + 0.03)
            balls.append(Ball(c: c, r: r))
        }

        let skirtN = 3 + Int(frand() * 3)
        for _ in 0..<skirtN {
            let x = 0.38 + frand() * 0.24
            let y = 0.46 + frand() * 0.05
            let r: Float = coreR * (0.78 + frand() * 0.30)
            balls.append(Ball(c: simd_float2(x, y), r: r))
        }

        let kBlend: Float = 8.0
        @inline(__always)
        func sdf(_ p: simd_float2) -> Float {
            var d: Float = .greatestFiniteMagnitude
            for b in balls {
                let l = simd_length(p - b.c) - b.r
                d = smin(d, l, kBlend)
            }
            return d
        }

        let edgeSoft: Float = 0.055 + 0.015 * frand()
        let topBias: Float  = 0.02  + 0.02  * frand()

        for y in 0..<H {
            let v = Float(y) / Float(H - 1)
            for x in 0..<W {
                let u = Float(x) / Float(W - 1)

                if x < 2 || y < 2 || x >= W - 2 || y >= H - 2 {
                    let o = (y * W + x) * 4
                    buf[o + 0] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
                    continue
                }

                let p = simd_float2(u, v)
                let d = sdf(p)

                let a = smooth01((-d) / edgeSoft)

                let ny = smooth01((0.55 - v) * 1.6)
                let shade = 1.0 + topBias * ny

                let g = 0.96 + 0.04 * vnoise(u * 48.0, v * 48.0)

                var r = 1.0 * shade * g
                var gch = 1.0 * shade * g
                var b = 1.0 * shade * g

                r = min(1, max(0, r))
                gch = min(1, max(0, gch))
                b = min(1, max(0, b))

                let o = (y * W + x) * 4
                buf[o + 0] = UInt8(r * a * 255.0 + 0.5)
                buf[o + 1] = UInt8(gch * a * 255.0 + 0.5)
                buf[o + 2] = UInt8(b * a * 255.0 + 0.5)
                buf[o + 3] = UInt8(a * 255.0 + 0.5)
            }
        }

        let data = CFDataCreate(nil, buf, buf.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cg = CGImage(
            width: W,
            height: H,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
