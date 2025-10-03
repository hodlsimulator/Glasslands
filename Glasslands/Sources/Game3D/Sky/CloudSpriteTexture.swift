//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a small set of reusable, premultiplied‑alpha “puff” textures.
//  All UIKit work happens on the main actor to avoid concurrency issues.
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
    /// Kept on MainActor so that `UIImage`/CoreGraphics never run off‑thread.
    nonisolated static func makeAtlas(
        size: Int = 256,
        seed: UInt32 = 0x0C10D5,
        count: Int = 4
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(64, size)

        let imgs: [UIImage] = await MainActor.run {
            var out: [UIImage] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                out.append(renderPuff(size: s, seed: seed &+ UInt32(i &* 977)))
            }
            return out
        }

        return Atlas(images: imgs, size: s)
    }

    // MARK: - Rendering (MainActor)

    @MainActor
    private static func renderPuff(size: Int, seed: UInt32) -> UIImage {
        let W = max(64, size), H = W
        let bytesPerRow = W * 4

        // Fully initialised buffer prevents garbage / black artefacts.
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        // Tiny LCG (deterministic, re‑entrant).
        var s = (seed == 0) ? 1 : seed
        @inline(__always) func urand() -> Float {
            s = 1664525 &* s &+ 1013904223
            return Float(s >> 8) * (1.0 / 16_777_216.0)
        }

        // Build 5–7 overlapping soft discs to get an irregular puff.
        struct Disc { var cx: Float; var cy: Float; var r: Float; var a: Float }
        var discs: [Disc] = []
        let discCount = 5 + Int(floorf(urand() * 3.0)) // 5..7
        for _ in 0..<discCount {
            // Position discs around centre with slight vertical bias (flatter base).
            let ang = urand() * .pi * 2
            let ring = (0.05 + 0.35 * urand()) * Float(W)
            let cx = Float(W) * 0.5 + cosf(ang) * ring * 0.45
            let cy = Float(H) * 0.5 + sinf(ang) * ring * 0.32 - 0.04 * Float(H)
            let r  = (0.18 + 0.42 * urand()) * Float(W) * 0.35
            let a  = 0.55 + 0.35 * urand()
            discs.append(.init(cx: cx, cy: cy, r: max(1, r), a: a))
        }

        // Paint: Lorentzian^2 profile gives that pillowy fall‑off.
        for y in 0..<H {
            let fy = Float(y) + 0.5
            for x in 0..<W {
                let fx = Float(x) + 0.5

                var d: Float = 0
                for disc in discs {
                    let dx = (fx - disc.cx) / disc.r
                    let dy = (fy - disc.cy) / disc.r
                    let q  = dx*dx + dy*dy
                    if q > 4 { continue }
                    let k: Float = 1.6
                    let shape = 1.0 / ((1.0 + k*q) * (1.0 + k*q))
                    d += disc.a * shape
                }

                // Normalise + gentle S‑curve to keep edges airy.
                d = max(0, min(1, d))
                d = d * (0.70 + 0.30 * d)

                // Premultiplied white (avoids dark fringes during alpha blending).
                let a = UInt8(d * 255.0 + 0.5)
                let i = (y * W + x) * 4
                buf[i + 0] = a
                buf[i + 1] = a
                buf[i + 2] = a
                buf[i + 3] = a
            }
        }

        // Upload as premultiplied‑alpha CGImage.
        let data = CFDataCreate(nil, buf, buf.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )!

        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

