//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a small atlas of soft “puff” sprites with subtle variants,
//  premultiplied alpha, WIDE transparent apron, and baked top-light shading.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {
    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    /// Builds N cloud‑puff variants (all premultiplied alpha).
    static func makeAtlas(
        size: Int = 512,
        seed: UInt32 = 0x0C10D5,
        count: Int = 4
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(256, size)

        let images: [UIImage] = await MainActor.run {
            var out: [UIImage] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                out.append(Self.buildImage(s, seed: seed &+ UInt32(i &* 7_919)))
            }
            return out
        }

        return Atlas(images: images, size: s)
    }
}

// MARK: - Implementation

private extension CloudSpriteTexture {

    @MainActor
    static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let bytesPerRow = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        // Deterministic LCG for repeatability.
        var state = (seed == 0) ? 1 : seed
        @inline(__always) func urand() -> Float {
            state = 1_664_525 &* state &+ 1_013_904_223
            return Float(state >> 8) * (1.0 / 16_777_216.0)
        }

        // Irregular silhouette from overlapping soft discs.
        struct Disc { var cx: Float; var cy: Float; var r: Float; var a: Float }
        var discs: [Disc] = []
        let discCount = 8 + Int(floorf(urand() * 3.0)) // 8–10
        for _ in 0..<discCount {
            // Slight bias upwards; gentle horizontal spread.
            let cx = 0.5 + (urand() - 0.5) * 0.32
            let cy = 0.52 + (urand() - 0.5) * 0.26
            let r  = 0.24 + urand() * 0.30
            let a  = 0.55 + urand() * 0.45
            discs.append(Disc(cx: cx, cy: cy, r: r, a: a))
        }

        // Density field with a generous transparent apron.
        var density = [Float](repeating: 0, count: W * H)
        let apronInner: Float = 0.06
        let apronSoft:  Float = 0.14

        for y in 0..<H {
            let fy = Float(y) / Float(H - 1)
            for x in 0..<W {
                let fx = Float(x) / Float(W - 1)
                var d: Float = 0

                for disc in discs {
                    let dx = (fx - disc.cx) / disc.r
                    let dy = (fy - disc.cy) / (disc.r * 0.82) // slightly squashed vertically
                    let q = sqrtf(dx*dx + dy*dy)
                    if q > 1.6 { continue }
                    // Lorentzian‑like falloff -> puffier core.
                    let k: Float = 1.6
                    d += disc.a * (1.0 / ((1.0 + k*q) * (1.0 + k*q)))
                }

                d = max(0, min(1, d))

                // Soft edge mask so UV rotation never samples the image border.
                let edge = min(min(fx, 1 - fx), min(fy, 1 - fy))
                let m = smoothstep(apronInner, apronSoft, edge)

                // Slight self‑brightening in thicker bits.
                density[y * W + x] = d * (0.72 + 0.28 * d) * m
            }
        }

        // Baked top‑light shading using gradient of density (greyscale).
        let lightDir = simd_normalize(simd_float2(0.0, -1.0)) // light from above

        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let d = density[i]

                let xm = density[i + (x > 0 ? -1 : 0)]
                let xp = density[i + (x < W - 1 ? 1 : 0)]
                let ym = density[i + (y > 0 ? -W : 0)]
                let yp = density[i + (y < H - 1 ? W : 0)]

                let nx = (xm - xp)
                let ny = (ym - yp)

                var shade = max(0.0, min(1.0, (nx * lightDir.x + ny * lightDir.y) * 1.05 + 0.88))
                shade = shade * (0.85 + 0.15 * d)

                let a = UInt8(min(1.0, d) * 255.0 + 0.5)
                let c = UInt8(min(1.0, d * shade) * 255.0 + 0.5)

                let o = i * 4
                buf[o + 0] = c
                buf[o + 1] = c
                buf[o + 2] = c
                buf[o + 3] = a // premultiplied alpha expected by .aOne
            }
        }

        let data = CFDataCreate(nil, buf, buf.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )!

        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    @inline(__always)
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        if x <= a { return 0 }
        if x >= b { return 1 }
        let t = (x - a) / (b - a)
        return t * t * (3 - 2 * t)
    }
}
