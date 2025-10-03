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
        width: Int = 4096,
        height: Int = 2048,
        coverage: Float = 0.38,      // lower → more cloud area
        thickness: Float = 0.32,     // higher → softer edges
        seed: Int32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = W * 4
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }
        @inline(__always) func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
        @inline(__always) func toByte(_ f: Float) -> UInt8 { UInt8(max(0, min(255, Int(f * 255.0)))) }
        @inline(__always) func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            if abs(d) < .ulpOfOne { return x < e0 ? 0 : 1 }
            return smooth01((x - e0) / d)
        }

        let deg = Float.pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Sky gradient colours (top → mid → bottom)
        let top = simd_float3(0.50, 0.74, 0.92)
        let mid = simd_float3(0.70, 0.86, 0.95)
        let bot = simd_float3(0.86, 0.93, 0.98)

        // Domain-warped 2D FBM (lat/long space) — fast and seam-free.
        let base  = GKNoise(GKBillowNoiseSource(frequency: 1.2, octaveCount: 5, persistence: 0.5, lacunarity: 2.0, seed: seed))
        let warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 101))
        let warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 202))

        let scale: Float = 1.8   // feature size (bigger → smaller details)

        for y in 0..<H {
            let v = (Float(y) + 0.5) / Float(H)             // 0 at top → 1 at bottom
            let phi = v * Float.pi                           // latitude (0..π)
            let upY = cosf(phi)                              // 1 at zenith → -1 at nadir

            // Sky gradient (no cubemap → no seams)
            var sky = mix3(bot, mid, clampf((upY + 0.20) * 0.80, 0, 1))
            sky = mix3(sky, top, clampf((upY + 1.00) * 0.50, 0, 1))

            for x in 0..<W {
                let u = (Float(x) + 0.5) / Float(W)         // 0..1 across
                let theta = u * 2 * Float.pi                 // longitude
                let dir = simd_float3(cosf(theta) * sinf(phi), upY, sinf(theta) * sinf(phi))

                // Domain-warped noise in equirectangular space (seam-free at u=0/1)
                let wx = Float(warpX.value(atPosition: vector_float2(u * 4.0, v * 2.0)))
                let wy = Float(warpY.value(atPosition: vector_float2(u * 4.0, v * 2.0)))
                var n  = Float(base .value(atPosition: vector_float2(u * scale + wx * 0.33,
                                                                      v * scale + wy * 0.33)))
                n = max(-1.0, min(1.0, n))
                var billow = Float(0.5 * n + 0.5)            // 0..1
                billow = pow(billow, 1.25)

                // Gravity bias: heavier bottoms, lighter tops
                let baseThr = clampf(coverage, 0, 1)
                let thick = max(0.001, thickness)
                let grav = (1 - clampf(upY, 0, 1))           // 0 at top → 1 near horizon
                let bias = grav * 0.25
                var a = smoothstep(baseThr - bias, baseThr - bias + thick, billow)

                // Flatten undersides slightly
                let flat = smoothstep(-0.15, 0.35, -dir.y)
                a = a * (0.90 + 0.10 * flat)

                // Horizon fade
                a *= clampf((upY + 0.20) * 1.4, 0, 1)

                // Silver lining facing the sun
                let sdot = max(0, simd_dot(dir, sunDir))
                let silver = pow(sdot, 10) * 0.6 + pow(sdot, 28) * 0.4
                let cloud = simd_float3(repeating: 0.84 + 0.30 * silver)

                let rgb = mix3(sky, cloud, a)

                let idx = y * bpr + x * 4
                pixels[idx + 0] = toByte(rgb.x)   // R
                pixels[idx + 1] = toByte(rgb.y)   // G
                pixels[idx + 2] = toByte(rgb.z)   // B
                pixels[idx + 3] = 255             // A
            }
        }

        var cgImg: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let basePtr = raw.baseAddress else { return }
            if let ctx = CGContext(data: basePtr,
                                   width: W, height: H,
                                   bitsPerComponent: 8, bytesPerRow: bpr,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                cgImg = ctx.makeImage()
            }
        }
        if let cg = cgImg { return UIImage(cgImage: cg, scale: 1, orientation: .up) }
        return UIImage()
    }
}
