//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a small set of reusable, pre‑multiplied alpha “puff” textures.
//  Textures are created on the main actor to avoid UIKit off‑thread issues.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {

    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    /// Build a small atlas of puffs with subtle shape variants.
    /// All UIKit work runs on the main actor (c77df77 pattern).
    nonisolated static func makeAtlas(size: Int = 256, seed: UInt32 = 0x0C10D5, count: Int = 4) async -> Atlas {
        await MainActor.run {
            var imgs: [UIImage] = []
            let n = max(1, min(8, count))
            for i in 0..<n {
                let s = seed &+ UInt32(i) &+ 0x9E37_79B9
                imgs.append(makePuffImage(size: size, seed: s))
            }
            return Atlas(images: imgs, size: size)
        }
    }

    // MARK: - Internals

    /// Produces a cauliflower‑style puff by summing several soft discs with
    /// slightly different centres/radii, then baking gentle top‑lit shading.
    @MainActor
    private static func makePuffImage(size: Int, seed: UInt32) -> UIImage {
        let W = max(64, size)
        let H = W
        let bytesPerRow = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func urand(_ s: inout UInt32) -> Float {
            s = 1664525 &* s &+ 1013904223
            return Float(s >> 8) * (1.0 / 16_777_216.0)
        }

        var s = (seed == 0) ? 1 : seed

        // Define 5–7 soft discs.
        let discCount = Int(5 + floorf(urand(&s) * 3.0 as Float))
        struct Disc { var cx: Float; var cy: Float; var r: Float; var a: Float }
        var discs: [Disc] = []
        for i in 0..<discCount {
            // Bias a couple of “caplets” towards the top.
            let biasTop: Float = (i < 2) ? -0.18 as Float : 0.0 as Float
            let cx = (urand(&s) * 0.30 as Float - 0.15 as Float)
            let cy = (urand(&s) * 0.25 as Float - 0.125 as Float) + biasTop
            let r  = 0.36 as Float + 0.18 as Float * urand(&s)
            let a  = 0.65 as Float + 0.35 as Float * urand(&s)
            discs.append(Disc(cx: cx, cy: cy, r: r, a: a))
        }

        // Sun direction in puff texture space (top‑left highlight).
        let sun = simd_float2(-0.5 as Float, -0.75 as Float)
        let sunN = simd_normalize(sun)

        // Render
        for y in 0..<H {
            let vy = (Float(y) / Float(H - 1)) * 2 - 1
            for x in 0..<W {
                let vx = (Float(x) / Float(W - 1)) * 2 - 1

                var dens: Float = 0
                var peak: Float = 0
                for d in discs {
                    let dx = (vx - d.cx) / (d.r * 1.05 as Float)
                    let dy = (vy - d.cy) / (d.r * 1.15 as Float)
                    let r2 = dx*dx + dy*dy
                    if r2 < 4.0 as Float {
                        let k: Float = 1.6
                        let v = d.a / ((1 + k*r2) * (1 + k*r2))
                        dens += v
                        peak = max(peak, v)
                    }
                }

                // Normalise and soft threshold.
                dens = max(0, dens)
                dens = dens / (1.0 as Float + dens)
                let alpha = powf(dens, 0.85 as Float)

                // Baked top‑lit shading (very gentle).
                let h = simd_dot(simd_float2(vx, vy), sunN)
                let shade: Float = 0.55 as Float + 0.35 as Float * max(0, -h) + 0.10 as Float * peak

                // Premultiplied.
                let white: Float = min(1.05 as Float, shade)
                let r = UInt8(min(255, Int(white * alpha * 255.0 as Float + 0.5 as Float)))
                let g = r
                let b = r
                let a = UInt8(min(255, Int(alpha * 255.0 as Float + 0.5 as Float)))

                let idx = (y * W + x) * 4
                buf[idx + 0] = r
                buf[idx + 1] = g
                buf[idx + 2] = b
                buf[idx + 3] = a
            }
        }

        // Make CGImage → UIImage.
        let data = Data(buf) as CFData
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg)
    }
}
