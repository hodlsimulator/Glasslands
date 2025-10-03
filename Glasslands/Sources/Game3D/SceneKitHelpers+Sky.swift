//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import UIKit
import GameplayKit
import simd

enum SkyGen {
    static func skyWithCloudsImage(
        width: Int = 2048,
        height: Int = 4096,
        coverage: Float = 0.48,   // lower than before → more visible clouds
        thickness: Float = 0.20,
        seed: Int32 = 424242
    ) -> UIImage {
        let W = max(64, width)
        let H = max(64, height)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = W * 4
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }
        @inline(__always) func lerp3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
        @inline(__always) func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            if abs(d) < .ulpOfOne { return x < e0 ? 0 : 1 }
            return smooth01((x - e0) / d)
        }
        @inline(__always) func n01(_ v: Float) -> Float { v * 0.5 + 0.5 }
        @inline(__always) func toByte(_ f: Float) -> UInt8 {
            let v = Int(f * 255.0)
            return UInt8(max(0, min(255, v)))
        }

        // Sky gradient (top → mid → bottom)
        let top = simd_float3(0.50, 0.74, 0.92)
        let mid = simd_float3(0.70, 0.86, 0.95)
        let bot = simd_float3(0.86, 0.93, 0.98)

        // FBM billow with light domain-warp (Float positions for GKNoise)
        let base  = GKBillowNoiseSource(frequency: 1.2, octaveCount: 5, persistence: 0.5, lacunarity: 2.0, seed: seed)
        let n0    = GKNoise(base)
        let warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 101))
        let warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 202))

        // Slightly larger features than before so clouds are obvious
        let scale: Float = 1.8

        for y in 0..<H {
            let v = Float(y) / Float(H - 1)
            let cTopMid = lerp3(top, mid, smooth01(min(1, v / 0.55)))
            let skyRGB  = lerp3(cTopMid, bot, smooth01(max(0, (v - 0.55) / 0.45)))

            for x in 0..<W {
                let u = Float(x) / Float(W - 1)

                // Domain-warped sample in image space (seam-free)
                let wx = warpX.value(atPosition: vector_float2(u * scale, v * scale))
                let wy = warpY.value(atPosition: vector_float2((u + 0.21) * scale, (v - 0.37) * scale))
                let uu = u * scale + wx * 0.18
                let vv = v * scale + wy * 0.18
                let raw = n0.value(atPosition: vector_float2(uu, vv))
                let n = pow(n01(raw), 1.45)

                // Cloud alpha
                let cov = clampf(coverage, 0, 1)
                let thk = max(0.001, thickness)
                var a = smoothstep(cov, cov + thk, n)

                // Fade OUT near the horizon (bottom of the image), not the zenith.
                // This removes that single “smudge” sitting on the horizon line.
                let horizonFade = smoothstep(0.0, 0.35, 1.0 - v)
                a *= horizonFade

                // Subtle silver lining towards a notional sun (top-right)
                let sunDir  = simd_normalize(simd_float3(0.4, -0.7, 0.6))
                let viewDir = simd_normalize(simd_float3(u - 0.5, v - 0.5, 1))
                let sunDot  = max(0, simd_dot(viewDir, sunDir))
                let silver  = pow(sunDot, 10) * 0.6 + pow(sunDot, 28) * 0.4

                var rgb = skyRGB
                if a > 0 {
                    let cloud = simd_float3(repeating: 0.86 + 0.28 * silver)
                    rgb = rgb * (1 - a) + cloud * a
                }

                let idx = y * bpr + x * 4
                pixels[idx + 0] = toByte(rgb.x)  // R
                pixels[idx + 1] = toByte(rgb.y)  // G
                pixels[idx + 2] = toByte(rgb.z)  // B
                pixels[idx + 3] = 255            // A
            }
        }

        var cgImg: CGImage?
        pixels.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            guard let ctx = CGContext(
                data: base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            cgImg = ctx.makeImage()
        }

        if let cg = cgImg { return UIImage(cgImage: cg, scale: 1, orientation: .up) }
        return UIImage()
    }
}
