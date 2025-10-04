//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates an atlas of soft **cumulus puff** sprites.
//  Design goals:
//   • All puffs share the same visual language (rounded, fluffy, soft edge)
//     with small, natural variations — so clouds feel consistent like the ref.
//   • Premultiplied alpha for .aOne blending (no halos).
//   • Wide **radial** apron so rotated billboards never show squares.
//   • Very subtle top‑light; no hard base clipping inside the sprite.
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {
    struct Atlas {
        let images: [UIImage]
        let size: Int
    }

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

// MARK: - Implementation -------------------------------------------------------

private extension CloudSpriteTexture {

    // Fast 2D value noise + 3‑octave FBM (branchless).
    static func h(_ x: Float, _ y: Float) -> Float {
        var n = sinf(x * 127.1 + y * 311.7) * 43758.5453
        n = n - floorf(n)
        return n
    }
    static func vnoise(_ x: Float, _ y: Float) -> Float {
        let ix = floorf(x), iy = floorf(y)
        let fx = x - ix,   fy = y - iy
        let a = h(ix,     iy)
        let b = h(ix + 1, iy)
        let c = h(ix,     iy + 1)
        let d = h(ix + 1, iy + 1)
        let u = fx*fx*(3 - 2*fx)
        let v = fy*fy*(3 - 2*fy)
        return a*(1-u)*(1-v) + b*u*(1-v) + c*(1-u)*v + d*u*v
    }
    static func fbm(_ x: Float, _ y: Float) -> Float {
        var f: Float = 0, a: Float = 0.5, s: Float = 1
        for _ in 0..<3 {
            f += a * vnoise(x * s, y * s)
            s *= 2; a *= 0.5
        }
        return f
    }

    @MainActor
    static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let bytesPerRow = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        // RNG for lobe placements
        var state = (seed == 0) ? 1 : seed
        @inline(__always) func urand() -> Float {
            state = 1_664_525 &* state &+ 1_013_904_223
            return Float(state >> 8) * (1.0 / 16_777_216.0)
        }

        // Elliptical Gaussian lobes (slightly wider than tall).
        struct Lobe { var cx: Float; var cy: Float; var rx: Float; var ry: Float; var w: Float }
        var lobes: [Lobe] = []
        let count = 7 + Int(urand() * 3) // 7–9 similar lobes for consistent look
        for i in 0..<count {
            let spreadX: Float = (i < 2) ? 0.36 : 0.26
            let spreadY: Float = (i < 2) ? 0.20 : 0.18
            let cx = 0.5 + (urand() - 0.5) * spreadX
            let cy = 0.50 + (urand() - 0.3) * spreadY  // tiny upward bias, but no hard base cut
            // Base size with small per‑lobe variation
            let s  = 0.23 + urand() * 0.22
            let rx = s * (1.10 + (urand() - 0.5) * 0.20)
            let ry = s * (0.92 + (urand() - 0.5) * 0.18)
            let w  = 0.55 + urand() * 0.35
            lobes.append(Lobe(cx: cx, cy: cy, rx: rx, ry: ry, w: w))
        }

        var density = [Float](repeating: 0, count: W * H)

        // Radial apron (circular) – keeps samples well away from texture edge.
        let apronInner: Float = 0.86
        let apronOuter: Float = 0.995

        // Centre for a slight vertical “cap” bias without cutting the base.
        let capBiasY: Float = 0.52

        for y in 0..<H {
            let fy = (Float(y) + 0.5) / Float(H)
            for x in 0..<W {
                let fx = (Float(x) + 0.5) / Float(W)

                // Soft union of lobes using multiplicative complement:
                //   union = 1 - Π(1 - w_i * gaussian)
                var keep: Float = 1.0
                for l in lobes {
                    let dx = (fx - l.cx)
                    let dy = (fy - l.cy)
                    let g = expf(-0.5 * ((dx*dx)/(l.rx*l.rx) + (dy*dy)/(l.ry*l.ry)))
                    keep *= (1.0 - l.w * g)
                }
                var d = 1.0 - keep
                d = min(1, max(0, d))

                // Slight cap thickening above the centre (no hard cut).
                // Adds a “puffed top” feeling like cumulus without making a bowl.
                let capBoost = max(0, (fy - capBiasY)) * 0.25
                d = min(1, d * (1.0 + capBoost))

                // Tiny rim noise to break perfect circularity (consistent style).
                let n = fbm(fx * 9.0, fy * 9.0)  // 0..~1
                let edge = 1 - d
                d += (n - 0.5) * 0.10 * edge      // stronger near edge, subtle overall
                d = min(1, max(0, d))

                // Radial apron mask.
                let rdx = (fx - 0.5) / 0.5
                let rdy = (fy - 0.5) / 0.5
                let rr  = min(1.5, sqrtf(rdx*rdx + rdy*rdy))
                let rimCut = smoothstep(apronInner, apronOuter, min(1.0, rr))
                let mask   = 1.0 - rimCut

                density[y * W + x] = d * mask
            }
        }

        // Gentle top‑light shading using gradient of density.
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

                // Soft shading only; keep clouds bright & cottony.
                var shade = max(0.0, min(1.0, (nx * lightDir.x + ny * lightDir.y) * 0.55 + 0.95))
                shade = shade * (0.92 + 0.08 * d)

                // Premultiplied alpha.
                let a = min(1.0, d)
                let c = min(1.0, a * shade)

                let o = i * 4
                buf[o + 0] = UInt8(c * 255.0 + 0.5)
                buf[o + 1] = UInt8(c * 255.0 + 0.5)
                buf[o + 2] = UInt8(c * 255.0 + 0.5)
                buf[o + 3] = UInt8(a * 255.0 + 0.5)
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
