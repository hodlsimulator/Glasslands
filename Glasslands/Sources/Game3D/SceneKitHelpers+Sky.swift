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
        width: Int = 1024,
        height: Int = 2048,
        coverage: Double = 0.52,
        thickness: Double = 0.23,
        seed: Int32 = 424242
    ) -> UIImage {
        let W = max(64, width)
        let H = max(64, height)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = W * 4
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
        @inline(__always) func lerp3(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        @inline(__always) func smooth01(_ x: Double) -> Double { let t = clampd(x, 0.0, 1.0); return t * t * (3.0 - 2.0 * t) }
        @inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let d = e1 - e0
            if abs(d) < .ulpOfOne { return x < e0 ? 0.0 : 1.0 }
            return smooth01((x - e0) / d)
        }
        @inline(__always) func n01(_ v: Double) -> Double { v * 0.5 + 0.5 }

        // Vertical sky gradient (top → mid → bottom)
        let top = SIMD3<Double>(0.50, 0.74, 0.92)
        let mid = SIMD3<Double>(0.70, 0.86, 0.95)
        let bot = SIMD3<Double>(0.86, 0.93, 0.98)

        // Billowy FBM + domain warp via GKNoise (seam-free in image space)
        let base = GKBillowNoiseSource(frequency: 1.2, octaveCount: 5, persistence: 0.5, lacunarity: 2.0, seed: seed)
        let n0 = GKNoise(base)
        let warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 101))
        let warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 202))
        let scale: Double = 2.6

        for y in 0..<H {
            let v = Double(y) / Double(H - 1)
            let cTopMid = lerp3(top, mid, smooth01(min(1.0, v / 0.55)))
            let skyRGB  = lerp3(cTopMid, bot, smooth01(max(0.0, (v - 0.55) / 0.45)))

            for x in 0..<W {
                let u = Double(x) / Double(W - 1)

                // Domain-warped FBM sample (use doubles for GKNoise)
                let wx = Double(warpX.value(atPosition: vector_double2(u * scale, v * scale)))
                let wy = Double(warpY.value(atPosition: vector_double2((u + 0.21) * scale, (v - 0.37) * scale)))
                let uu = u * scale + wx * 0.18
                let vv = v * scale + wy * 0.18
                let raw = Double(n0.value(atPosition: vector_double2(uu, vv)))
                let n = pow(n01(raw), 1.45)

                let cov = clampd(coverage, 0.0, 1.0)
                let thk = max(0.001, thickness)
                var a = smoothstep(cov, cov + thk, n)

                // Horizon fade
                let horizon = clampd((v - 0.12) * 1.5, 0.0, 1.0)
                a *= horizon

                // Silver lining towards a notional sun (top-right)
                let sunDir  = simd_normalize(simd_double3(0.4, -0.7, 0.6))
                let viewDir = simd_normalize(simd_double3(u - 0.5, v - 0.5, 1.0))
                let sunDot  = max(0.0, simd_dot(viewDir, sunDir))
                let silver  = pow(sunDot, 10.0) * 0.6 + pow(sunDot, 28.0) * 0.4

                var rgb = skyRGB
                if a > 0.0 {
                    let cloud = SIMD3<Double>(repeating: 0.84 + 0.30 * silver)
                    rgb = rgb * (1.0 - a) + cloud * a
                }

                let idx = y * bpr + x * 4
                pixels[idx + 0] = UInt8(max(0, min(255, Int(rgb.x * 255.0))))  // R
                pixels[idx + 1] = UInt8(max(0, min(255, Int(rgb.y * 255.0))))  // G
                pixels[idx + 2] = UInt8(max(0, min(255, Int(rgb.z * 255.0))))  // B
                pixels[idx + 3] = 255                                           // A
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
