//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Soft cumulus “puff” sprites (premultiplied alpha).
//  Silhouette comes from a small metaball SDF. Very light vertical tint and
//  micro-variation to avoid banding. Adds a hard transparent 2-px frame so
//  sampling at the edges is clamp/mip safe.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {

    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    /// Builds a tiny atlas of puff images (sRGB, premultiplied alpha).
    static func makeAtlas(
        size: Int = 512,
        seed: UInt32 = 0xC10D5,
        count: Int = 6
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(256, size)

        let images: [UIImage] = await MainActor.run {
            (0..<n).map { i in
                buildImage(s, seed: seed &+ UInt32(i) &* 0x9E37_79B9)
            }
        }
        return Atlas(images: images, size: s)
    }

    // MARK: - Private

    @inline(__always)
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        if x <= a { return 0 }
        if x >= b { return 1 }
        let t = (x - a) / (b - a)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private static func hash2(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374_761_393
        h &+= UInt32(bitPattern: y) &* 668_265_263
        h ^= h >> 13
        h &*= 1_274_126_177
        return Float(h & 0x00FF_FFFF) * (1.0 / 16_777_216.0)
    }

    // tiny value noise for micro grain
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
        // smooth union
        let res = -log(exp(-k*a) + exp(-k*b)) / k
        return res.isFinite ? res : min(a, b)
    }

    @MainActor
    private static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let stride = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        // simple LCG
        var state = seed == 0 ? 1 : Int(seed)
        @inline(__always) func frand() -> Float {
            state = 1664525 &* state &+ 1013904223
            return Float((state >> 8) & 0xFFFFFF) * (1.0 / 16_777_216.0)
        }

        struct Ball { var c: simd_float2; var r: Float }
        var balls: [Ball] = []

        // Core + lobes → cauliflower silhouette
        let coreR: Float = 0.30 + frand() * 0.05
        balls.append(Ball(c: simd_float2(0.50, 0.53 + frand()*0.03), r: coreR))

        let capN = 4 + Int(frand() * 3) // 4–6
        for _ in 0..<capN {
            let ang = (Float.pi * 0.85) * (frand() - 0.5)   // prefer top half
            let rr: Float = coreR * (0.62 + frand() * 0.20)
            let off: Float = coreR * (0.70 + frand() * 0.28)
            let cx = 0.50 + cosf(ang) * off * 0.85
            let cy = 0.52 - sinf(ang) * off
            balls.append(Ball(c: simd_float2(cx, cy), r: rr))
        }

        let baseN = 3 + Int(frand() * 3) // 3–5
        for i in 0..<baseN {
            let t = (Float(i) + frand()*0.25) / Float(max(1, baseN - 1)) - 0.5
            let cx = 0.50 + t * (0.60 + frand() * 0.10)
            let cy = 0.58 + frand() * 0.04
            let rr: Float = coreR * (0.72 + frand() * 0.20)
            balls.append(Ball(c: simd_float2(cx, cy), r: rr))
        }

        let microN = 3 + Int(frand() * 3) // 3–5 tiny edge seeds
        for _ in 0..<microN {
            let ang = Float.random(in: 0...(2*Float.pi))
            let cx = 0.50 + cosf(ang) * (coreR * (0.90 + frand()*0.28))
            let cy = 0.52 + sinf(ang) * (coreR * (0.90 + frand()*0.28))
            let rr: Float = coreR * (0.22 + frand() * 0.12)
            balls.append(Ball(c: simd_float2(cx, cy), r: rr))
        }

        // signed distance to union of balls
        let kBlend: Float = 12.0
        @inline(__always)
        func sdf(_ p: simd_float2) -> Float {
            var d: Float = .greatestFiniteMagnitude
            for b in balls {
                let l = simd_length(p - b.c) - b.r
                d = smin(d, l, kBlend)
            }
            return d
        }

        let edgeSoft: Float = 0.055 + 0.015 * frand()  // falloff thickness
        let topBias:  Float = 0.02 + 0.02 * frand()    // slight brightening top

        for y in 0..<H {
            let fy = (Float(y) + 0.5) / Float(H)
            for x in 0..<W {
                let fx = (Float(x) + 0.5) / Float(W)
                var a = 1.0 - smoothstep(0.0, edgeSoft, sdf(simd_float2(fx, fy)))
                a = max(0, min(1, a))

                // gentle vertical tint (brighter at top), plus micro noise
                let vert = 1.0 + topBias * (0.5 - (fy - 0.5))
                let n = (vnoise(fx * 32, fy * 32) - 0.5) * 0.02

                // bright, almost flat shade; premultiply
                let shade = min(1.0, 0.97 * vert + n)
                let c = min(1.0, a * shade)

                let o = (y * W + x) * 4
                buf[o + 0] = UInt8(c * 255.0 + 0.5)
                buf[o + 1] = UInt8(c * 255.0 + 0.5)
                buf[o + 2] = UInt8(c * 255.0 + 0.5)
                buf[o + 3] = UInt8(a * 255.0 + 0.5)
            }
        }

        // hard transparent frame (2px) for clamp/mip safety
        if W >= 4 && H >= 4 {
            for y in 0..<H {
                for x in 0..<W {
                    if x < 2 || y < 2 || x >= W - 2 || y >= H - 2 {
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
}
