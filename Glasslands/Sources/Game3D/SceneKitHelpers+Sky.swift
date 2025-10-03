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
        let W = max(64, width), H = max(64, height)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = W * 4
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        // Smooth vertical sky gradient (top→bottom)
        let top = SIMD3<Double>(0.50, 0.74, 0.92)
        let mid = SIMD3<Double>(0.70, 0.86, 0.95)
        let bot = SIMD3<Double>(0.86, 0.93, 0.98)
        @inline(__always) func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        @inline(__always) func smooth(_ x: Double) -> Double { let t = max(0.0, min(1.0, x)); return t*t*(3 - 2*t) }

        // Billowy, seamless GKNoise with gentle domain-warp for fluffy cumulus
        let base = GKBillowNoiseSource(frequency: 1.2, octaveCount: 5, persistence: 0.5, lacunarity: 2.0, seed: seed)
        let n0 = GKNoise(base)
        let warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 101))
        let warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seed &+ 202))

        // Noise scale controls cloud size
        let scale: Double = 2.6
        func n01(_ v: Double) -> Double { v * 0.5 + 0.5 }

        for y in 0..<H {
            let v = Double(y) / Double(H - 1)
            // 3-stop gradient (top→mid→bottom)
            let cTopMid = mix(top, mid, smooth(min(1.0, v / 0.55)))
            let skyRGB = mix(cTopMid, bot, smooth(max(0.0, (v - 0.55) / 0.45)))

            for x in 0..<W {
                let u = Double(x) / Double(W)

                // Domain-warp the FBM sample in UV space (seamless because we never wrap an atlas)
                let wx = Double(warpX.value(atPosition: vector_float2(Float(u * scale), Float(v * scale))))
                let wy = Double(warpY.value(atPosition: vector_float2(Float((u + 0.21) * scale), Float((v - 0.37) * scale))))
                let uu = u * scale + wx * 0.18
                let vv = v * scale + wy * 0.18
                let raw = Double(n0.value(atPosition: vector_float2(Float(uu), Float(vv))))

                var n = pow(n01(raw), 1.45)              // billowy
                let cov = max(0.0, min(1.0, coverage))
                let thk = max(0.001, thickness)
                var a = smoothstep(cov, cov + thk, n)    // cloud alpha before horizon fade

                // Horizon fade (thin clouds near horizon)
                let horizon = max(0.0, min(1.0, (v - 0.12) * 1.5))
                a *= horizon

                // Silver lining towards an implied sun (top-right)
                let sunDir = normalize(SIMD3<Double>(0.4, -0.7, 0.6))
                let viewDir = normalize(SIMD3<Double>((u - 0.5), (v - 0.5), 1.0))
                let sunDot = max(0.0, dot(viewDir, sunDir))
                let silver = pow(sunDot, 10.0) * 0.6 + pow(sunDot, 28.0) * 0.4

                var r = skyRGB.x
                var g = skyRGB.y
                var b = skyRGB.z

                if a > 0.0 {
                    let cloudR = 0.84 + 0.30 * silver
                    let cloudG = 0.84 + 0.30 * silver
                    let cloudB = 0.84 + 0.30 * silver
                    r = r * (1.0 - a) + cloudR * a
                    g = g * (1.0 - a) + cloudG * a
                    b = b * (1.0 - a) + cloudB * a
                }

                let idx = y * bpr + x * 4
                pixels[idx + 0] = UInt8(max(0, min(255, Int(b * 255.0))))
                pixels[idx + 1] = UInt8(max(0, min(255, Int(g * 255.0))))
                pixels[idx + 2] = UInt8(max(0, min(255, Int(r * 255.0))))
                pixels[idx + 3] = 255
            }
        }

        guard let ctx = CGContext(data: &pixels, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else {
            return UIImage()
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
