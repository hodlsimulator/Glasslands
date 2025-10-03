//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a tiny atlas of soft “puff” sprites with subtle variants,
//  premultiplied alpha, strong transparent apron, and baked top-light shading.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {
    struct Atlas { let images: [UIImage]; let size: Int }

    static func makeAtlas(
        size: Int = 512,
        seed: UInt32 = 0x0C10D5,
        count: Int = 4
    ) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(128, size)

        let images: [UIImage] = await MainActor.run {
            var out: [UIImage] = []; out.reserveCapacity(n)

            @inline(__always)
            func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
                if x <= a { return 0 }
                if x >= b { return 1 }
                let t = (x - a) / (b - a)
                return t * t * (3 - 2 * t)
            }

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

                struct Disc { var cx: Float; var cy: Float; var r: Float; var a: Float }
                var discs: [Disc] = []
                let discCount = 7 + Int(floorf(urand() * 3.0)) // 7..9
                for _ in 0..<discCount {
                    let rr   = 0.26 + 0.32 * urand()
                    let th   = 2 * Float.pi * urand()
                    let dist = 0.04 + 0.34 * urand()
                    let cx   = 0.5 + cosf(th) * dist
                    let cy   = 0.5 + sinf(th) * dist
                    let a    = 0.55 + 0.45 * urand()
                    discs.append(Disc(cx: cx, cy: cy, r: rr, a: a))
                }

                // Wide transparent apron at edges to kill any rectangles when magnified.
                let apronInner: Float = 0.10  // 10% fully transparent border start
                let apronSoft:  Float = 0.18  // fade to fully opaque towards centre

                // Build density + apply apron.
                var density = [Float](repeating: 0, count: W * H)
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
                        // Aperture mask from the edges towards centre.
                        let edge = min(min(fx, 1 - fx), min(fy, 1 - fy)) // 0 at edge .. 0.5 at centre
                        let m = smoothstep(apronInner, apronSoft, edge)   // 0 near edge → 1 near centre
                        density[y * W + x] = d * (0.72 + 0.28 * d) * m
                    }
                }

                // Baked top-light grey shading, no colour tint.
                let lightDir = simd_normalize(simd_float2(0.0, -1.0))
                for y in 0..<H {
                    for x in 0..<W {
                        let i = y * W + x
                        let d = density[i]

                        let xm = density[i + (x > 0     ? -1 : 0)]
                        let xp = density[i + (x < W - 1 ?  1 : 0)]
                        let ym = density[i + (y > 0     ? -W : 0)]
                        let yp = density[i + (y < H - 1 ?  W : 0)]
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
                        buf[o + 3] = a
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
