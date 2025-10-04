//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Generates a small atlas of soft cumulus puff sprites.
//  – Premultiplied alpha (for .aOne blending).
//  – Wide **radial** apron (edge‑safe rotation).
//  – Flat base weighting + lumpy cap via 3‑octave FBM value noise.
//  – Gentle top‑light; no ring artefacts.
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

        // Elliptical lobes, slightly wider than tall.
        struct Ell { var cx: Float; var cy: Float; var rx: Float; var ry: Float; var w: Float }
        var els: [Ell] = []
        let count = 9 + Int(urand() * 3) // 9–11
        for i in 0..<count {
            let spreadX: Float = (i < 3) ? 0.40 : 0.28
            let spreadY: Float = (i < 3) ? 0.22 : 0.18
            let cx = 0.5 + (urand() - 0.5) * spreadX
            let cy = 0.56 + (urand() - 0.5) * spreadY
            let s  = 0.24 + urand() * 0.28
            let rx = s * (1.10 + (urand() - 0.5) * 0.25)
            let ry = s * (0.85 + (urand() - 0.5) * 0.18)
            let w  = 0.55 + urand() * 0.45  // lobe weight
            els.append(Ell(cx: cx, cy: cy, rx: rx, ry: ry, w: w))
        }

        var density = [Float](repeating: 0, count: W * H)

        // Radial apron (circular) – keeps samples well away from texture edge.
        let apronInner: Float = 0.82
        let apronOuter: Float = 0.99

        // Base line for a flatter cumulus base (UV space).
        let baseY: Float = 0.56

        for y in 0..<H {
            let fy = (Float(y) + 0.5) / Float(H)
            for x in 0..<W {
                let fx = (Float(x) + 0.5) / Float(W)

                // Soft union of ellipses using multiplicative complement:
                //   union = 1 - Π(1 - v_i)
                // Each lobe uses a smoothstep on the normalised ellipse radius.
                var keep: Float = 1.0
                for e in els {
                    let dx = (fx - e.cx) / e.rx
                    let dy = (fy - e.cy) / e.ry
                    let q  = sqrtf(dx*dx + dy*dy)
                    // 1 inside .. 0 outside with soft edge
                    let v  = (1.0 - smoothstep(0.82, 1.05, q)) * e.w
                    keep *= (1.0 - v)
                }
                var d = 1.0 - keep
                d = min(1, max(0, d))

                // Crisp, flat-ish base: soft mask that fades rapidly below baseY.
                let baseMask = smoothstep(baseY - 0.02, baseY + 0.10, fy)
                d *= baseMask

                // Lumpy cap via FBM noise near the rim and above the base.
                let nx = fx * 9.0, ny = fy * 9.0
                let n  = fbm(nx, ny)                         // 0..~1
                let rim = (1 - d)                            // stronger near edge
                let cap = smoothstep(0.0, 0.3, baseY - (fy - 0.02)) // only above base
                d += (n - 0.5) * 0.20 * rim * cap
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

                // Very subtle shading to avoid ring artefacts.
                var shade = max(0.0, min(1.0, (nx * lightDir.x + ny * lightDir.y) * 0.6 + 0.94))
                shade = shade * (0.90 + 0.10 * d)

                // Premultiplied alpha. Keep clouds bright; shade is gentle.
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
