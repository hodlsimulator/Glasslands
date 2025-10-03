//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a tiny atlas of soft “puff” sprites with subtle shape variants.
//  Premultiplied‑alpha is used to avoid dark fringes when blending.
//
//  UIKit/CoreGraphics work stays on the main actor to avoid concurrency issues.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {
    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

    /// Builds a small set of reusable, premultiplied‑alpha puff textures.
    /// Kept on MainActor so UIImage/CoreGraphics never run off‑thread.
    static func makeAtlas(
        size: Int = 256,
        seed: UInt32 = 0x0C10D5,
        count: Int = 4
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(64, size)

        let images: [UIImage] = await MainActor.run {
            var out: [UIImage] = []
            out.reserveCapacity(n)

            @inline(__always)
            func buildImage(_ seed: UInt32) -> UIImage {
                let W = s, H = s
                let bytesPerRow = W * 4
                var buf = [UInt8](repeating: 0, count: W * H * 4)

                // Tiny deterministic LCG.
                var state = (seed == 0) ? 1 : seed
                @inline(__always) func urand() -> Float {
                    state = 1664525 &* state &+ 1013904223
                    return Float(state >> 8) * (1.0 / 16_777_216.0)
                }

                // Compose 5–7 soft discs to get an irregular puff silhouette.
                struct Disc { var cx: Float; var cy: Float; var r: Float; var a: Float }
                var discs: [Disc] = []
                let discCount = 5 + Int(floorf(urand() * 3.0)) // 5..7
                for _ in 0..<discCount {
                    let rr   = 0.28 + 0.28 * urand()
                    let th   = 2 * Float.pi * urand()
                    let dist = 0.05 + 0.36 * urand()
                    let cx   = 0.5 + cosf(th) * dist
                    let cy   = 0.5 + sinf(th) * dist
                    let a    = 0.45 + 0.55 * urand()
                    discs.append(Disc(cx: cx, cy: cy, r: rr, a: a))
                }

                for y in 0..<H {
                    for x in 0..<W {
                        let fx = (Float(x) + 0.5) / Float(W)
                        let fy = (Float(y) + 0.5) / Float(H)
                        var d: Float = 0

                        for disc in discs {
                            let dx = (fx - disc.cx) / disc.r
                            let dy = (fy - disc.cy) / disc.r
                            let q  = dx*dx + dy*dy
                            if q > 4 { continue }
                            // Smooth profile with airy edge.
                            let k: Float = 1.6
                            d += disc.a * (1.0 / ((1.0 + k*q) * (1.0 + k*q)))
                        }

                        d = max(0, min(1, d))
                        d = d * (0.70 + 0.30 * d) // gentle S‑curve

                        let a = UInt8(d * 255.0 + 0.5)
                        let i = (y * W + x) * 4
                        // Premultiplied white.
                        buf[i + 0] = a
                        buf[i + 1] = a
                        buf[i + 2] = a
                        buf[i + 3] = a
                    }
                }

                let data     = CFDataCreate(nil, buf, buf.count)!
                let provider = CGDataProvider(data: data)!
                let cs       = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let cg       = CGImage(
                    width: W, height: H,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                    space: cs,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                )!
                return UIImage(cgImage: cg, scale: 1, orientation: .up)
            }

            for i in 0..<n { out.append(buildImage(seed &+ UInt32(i &* 977))) }
            return out
        }

        return Atlas(images: images, size: s)
    }
}
