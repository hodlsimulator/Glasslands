//
//  CloudSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
// Atlas of soft **cumulus puff** sprites.
//  – SDF metaballs (smooth union of circles) for a cotton‑wool silhouette.
//  – Wide radial apron so rotated billboards never show square edges.
//  – Subtle top‑light; bright, cohesive look like the reference.
//  – Premultiplied alpha for .aOne blending (no halos).
//

import UIKit
import CoreGraphics
import simd

enum CloudSpriteTexture {
    struct Atlas { let images: [UIImage]; let size: Int }

    static func makeAtlas(size: Int = 512, seed: UInt32 = 0xC10D5, count: Int = 4) async -> Atlas {
        let n = max(1, min(8, count))
        let s = max(256, size)
        let images: [UIImage] = await MainActor.run {
            (0..<n).map { Self.buildImage(s, seed: seed &+ UInt32($0 &* 7919)) }
        }
        return Atlas(images: images, size: s)
    }
}

// MARK: - Implementation

private extension CloudSpriteTexture {

    // Fast integer hash -> 0..1
    static func hash2(_ x: Int32, _ y: Int32) -> Float {
        let n = sinf(Float(x) * 127.1 + Float(y) * 311.7) * 43758.5453
        return n - floorf(n)
    }
    static func vnoise(_ x: Float, _ y: Float) -> Float {
        let ix = floorf(x), iy = floorf(y)
        let fx = x - ix,   fy = y - iy
        let a = hash2(Int32(ix),     Int32(iy))
        let b = hash2(Int32(ix + 1), Int32(iy))
        let c = hash2(Int32(ix),     Int32(iy + 1))
        let d = hash2(Int32(ix + 1), Int32(iy + 1))
        let u = fx*fx*(3 - 2*fx)
        let v = fy*fy*(3 - 2*fy)
        return a*(1-u)*(1-v) + b*u*(1-v) + c*(1-u)*v + d*u*v
    }
    static func fbm(_ x: Float, _ y: Float) -> Float {
        var f: Float = 0, a: Float = 0.5, s: Float = 1
        for _ in 0..<3 { f += a * vnoise(x*s, y*s); s *= 2; a *= 0.5 }
        return f
    }

    // Smooth min (metaball blend) – stable, nice lobes.
    @inline(__always)
    static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        // Exponential smooth min
        let res = -log(exp(-k*a) + exp(-k*b)) / k
        return res.isFinite ? res : min(a, b)
    }

    @MainActor
    static func buildImage(_ size: Int, seed: UInt32) -> UIImage {
        let W = size, H = size
        let stride = W * 4
        var buf = [UInt8](repeating: 0, count: W * H * 4)

        // RNG (deterministic)
        var state = seed == 0 ? 1 : Int(seed)
        @inline(__always) func frand() -> Float {
            state = 1664525 &* state &+ 1013904223
            return Float((state >> 8) & 0xFFFFFF) * (1.0 / 16777216.0)
        }

        // --- Metaball layout (in UV space 0..1) ---
        // One dominant core + 4–6 small lobes clustered around the upper half;
        // no hard cut at the base – flatness comes from how puffs stack in world.
        struct Ball { var c: simd_float2; var r: Float }
        var balls: [Ball] = []

        // Core
        let coreR: Float = 0.28 + frand() * 0.05
        balls.append(Ball(c: simd_float2(0.50, 0.52 + frand()*0.03), r: coreR))

        // Cap lobes
        let capN = 4 + Int(frand() * 3) // 4–6
        for i in 0..<capN {
            let ang = (Float(i) / Float(capN)) * (.pi) + (frand()-0.5) * 0.3   // mostly top half
            let dist: Float = coreR * (0.65 + frand()*0.25)
            let r: Float = coreR * (0.55 + frand()*0.18)
            let cx = 0.50 + cos(ang) * dist
            let cy = 0.52 + sin(ang) * dist * 0.85
            balls.append(Ball(c: simd_float2(cx, cy), r: r))
        }

        // Occasional side lobe
        if frand() < 0.5 {
            let sideR = coreR * (0.45 + frand()*0.10)
            let sideX = 0.50 + (frand() < 0.5 ? -1.0 : 1.0) * (coreR * (0.65 + frand()*0.2))
            balls.append(Ball(c: simd_float2(sideX, 0.50 + frand()*0.02), r: sideR))
        }

        // Radial apron (ensures safe rotation on a clamped sampler).
        let apronInner: Float = 0.86
        let apronOuter: Float = 0.996

        // Field softness & rim noise
        let kBlend: Float = 10.0         // higher = tighter union
        let edgeSoft: Float = 0.02       // SDF feather to alpha
        let noiseAmt: Float = 0.08       // subtle irregular rim

        func sdf(_ p: simd_float2) -> Float {
            var d: Float = .greatestFiniteMagnitude
            for b in balls {
                let l = length(p - b.c) - b.r
                d = smin(d, l, kBlend)
            }
            return d
        }

        for y in 0..<H {
            let fy = (Float(y) + 0.5) / Float(H)
            for x in 0..<W {
                let fx = (Float(x) + 0.5) / Float(W)
                let p = simd_float2(fx, fy)

                // Raw SDF and soft alpha
                var d = sdf(p)

                // Add a tiny rim noise to break perfect circularity.
                let n = fbm(fx * 8.0, fy * 8.0)    // 0..~1
                d -= (n - 0.5) * noiseAmt

                // Map SDF -> density 0..1 (inside -> 1).
                var a = 1.0 - smoothstep(0.0, edgeSoft, d)
                a = max(0, min(1, a))

                // Radial apron mask (circular)
                let dx = (fx - 0.5) / 0.5
                let dy = (fy - 0.5) / 0.5
                let r = min(1.5, sqrtf(dx*dx + dy*dy))
                let apron = 1.0 - smoothstep(apronInner, apronOuter, min(1.0, r))
                a *= apron

                // Very gentle top‑light using the SDF gradient.
                // Central difference (2 texels apart to keep stable on small sprites).
                let eps: Float = 2.0 / Float(W)
                let nx = sdf(simd_float2(fx + eps, fy)) - sdf(simd_float2(fx - eps, fy))
                let ny = sdf(simd_float2(fx, fy + eps)) - sdf(simd_float2(fx, fy - eps))
                let L = simd_normalize(simd_float2(0.0, -1.0))
                var shade = max(0.0, min(1.0, (-(nx*L.x + ny*L.y)) * 0.6 + 0.92))
                shade = shade * (0.92 + 0.08 * a)

                // Premultiplied alpha.
                let c = min(1.0, a * shade)
                let o = (y * W + x) * 4
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
            bytesPerRow: stride,
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
