//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import UIKit
import CoreGraphics
import simd

/// Sky generator façade — builds a single equirectangular sky texture
/// (gradient + cloud puffs) and blends a planar zenith cap to avoid polar artefacts.
enum SkyGen {
    static var defaultCoverage: Float = 0.30   // 0.26–0.34 typical “nice day”

    private struct Key: Hashable {
        let w: Int, h: Int
        let covQ: Int, thickQ: Int
        let seed: UInt32
        let sunAzQ: Int, sunElQ: Int
    }

    private static var cache: [Key: UIImage] = [:]

    static func skyWithCloudsImage(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = defaultCoverage,
        thickness: Float = 0.44,             // 0.38–0.65: bigger = softer edges
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)

        let key = Key(
            w: W, h: H,
            covQ: Int((coverage * 1000).rounded()),
            thickQ: Int((thickness * 1000).rounded()),
            seed: seed,
            sunAzQ: Int((sunAzimuthDeg * 10).rounded()),
            sunElQ: Int((sunElevationDeg * 10).rounded())
        )
        if let img = cache[key] { return img }

        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        // --- sun vector (for subtle haze cue) --------------------------------
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // --- bluer palette (top → horizon) -----------------------------------
        let SKY_TOP = simd_float3(0.30, 0.56, 0.96)
        let SKY_MID = simd_float3(0.56, 0.74, 0.96)
        let SKY_BOT = simd_float3(0.86, 0.92, 0.98)

        // Early-out path: gradient only.
        if coverage <= 0 {
            for j in 0..<H {
                let v = Float(j) / Float(H - 1) // 0 = zenith
                let t = SkyMath.smooth01(v)
                var base = SkyMath.mix3(SkyMath.mix3(SKY_TOP, SKY_MID, t),
                                        SkyMath.mix3(SKY_MID, SKY_BOT, t), t)

                // Very mild brightening toward the sun.
                let phi = v * .pi
                let dir = simd_float3(0, cosf(phi), 0)
                let sunLift = max(0, simd_dot(dir, sunDir))
                base += simd_float3(repeating: sunLift * 0.010)

                let row = j * W * 4
                for i in 0..<W {
                    let idx = row + i * 4
                    pixels[idx + 0] = SkyMath.toByte(base.x)
                    pixels[idx + 1] = SkyMath.toByte(base.y)
                    pixels[idx + 2] = SkyMath.toByte(base.z)
                    pixels[idx + 3] = 255
                }
            }
            let img = imageFromRGBA(pixels: pixels, width: W, height: H)
            cache[key] = img
            return img
        }

        // --- build fields -----------------------------------------------------
        // Lat‑long “good clouds” field (elliptical puffs).
        let fieldLL = CloudFieldLL.build(width: max(64, W / 3),
                                         height: max(32, H / 3),
                                         coverage: coverage,
                                         seed: seed)

        // Planar zenith cap to remove circular artefacts/void at the pole.
        // Blend band: upY ∈ [0.78, 0.90] (~39°..26° from zenith).
        let capBlendStart: Float = 0.90
        let capBlendEnd:   Float = 0.78
        let fieldCap = ZenithCapField.build(size: max(128, W / 2),
                                            seed: seed,
                                            densityScale: 0.90)

        // --- final render -----------------------------------------------------
        let thick = max(0.001, thickness)

        for j in 0..<H {
            let v = Float(j) / Float(H - 1) // 0 = zenith, 1 = horizon
            let phi = v * .pi
            let upY = cosf(phi)
            let sinPhi = sinf(phi)

            // Gradient base (bluer) + subtle directional haze.
            let t = SkyMath.smooth01(v)
            var sky = SkyMath.mix3(SkyMath.mix3(SKY_TOP, SKY_MID, t),
                                   SkyMath.mix3(SKY_MID, SKY_BOT, t), t)
            let dirYOnly = simd_float3(0, upY, 0)
            let sunLift = max(0, simd_dot(dirYOnly, sunDir))
            sky += simd_float3(repeating: sunLift * 0.010)

            let row = j * W * 4
            for i in 0..<W {
                let u = Float(i) / Float(W - 1)

                // Per‑pixel jitter to break threshold banding.
                let bits = SkyMath.h2(Int32(i), Int32(j), seed &+ 0xBEEF_CAFE)
                let jitter = (Float(bits & 0xFFFF) / 65535.0 - 0.5) * 0.04

                // Base lat‑long billow.
                let billowLL = fieldLL.sample(u: u, v: v)

                // Planar cap sample (orthographic projection of top hemisphere).
                let theta = (u - 0.5) * 2 * .pi
                let dir = simd_float3(sinf(theta) * sinPhi, upY, cosf(theta) * sinPhi)
                let uCap = 0.5 + 0.5 * dir.x
                let vCap = 0.5 + 0.5 * dir.z
                let billowCap = fieldCap.sample(u: uCap, v: vCap)

                // Blend cap near the top.
                let capT = SkyMath.smoothstep(capBlendEnd, capBlendStart, upY)
                let billow = billowLL + (billowCap - billowLL) * capT

                // Threshold with horizon/zenith bias.
                var grav = 1 - SkyMath.clampf(upY, 0, 1)
                grav = grav * (0.65 + 0.35 * grav)
                let baseThr = SkyMath.clampf(coverage - 0.06 * grav, 0, 1)
                var a = SkyMath.smoothstep(baseThr + jitter, baseThr + jitter + thick, billow)

                // Slightly denser near horizon.
                let flat = SkyMath.smoothstep(-0.10, 0.40, -upY)
                a *= (0.90 + 0.10 * flat)

                // Silver lining using integer powers (cheap).
                let nd = max(0.0 as Float, simd_dot(simd_normalize(dir), sunDir))
                let nd2 = nd * nd, nd4 = nd2 * nd2, nd8 = nd4 * nd4
                let nd16 = nd8 * nd8, nd12 = nd8 * nd4, nd28 = nd16 * nd8 * nd4
                let silver = nd12 * 0.42 + nd28 * 0.34

                let cloud = simd_float3(repeating: 0.90 + 0.22 * silver)
                let rgb = SkyMath.mix3(sky, cloud, a)

                let idx = row + i * 4
                pixels[idx + 0] = SkyMath.toByte(rgb.x)
                pixels[idx + 1] = SkyMath.toByte(rgb.y)
                pixels[idx + 2] = SkyMath.toByte(rgb.z)
                pixels[idx + 3] = 255
            }
        }

        let img = imageFromRGBA(pixels: pixels, width: W, height: H)
        cache[key] = img
        return img
    }

    // Packer is kept here so this file remains the façade.
    private static func imageFromRGBA(pixels: [UInt8], width: Int, height: Int) -> UIImage {
        let bpr = width * 4
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let img = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: img)
    }
}
