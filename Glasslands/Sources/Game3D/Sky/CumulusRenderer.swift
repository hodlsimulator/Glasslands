//
//  CumulusRenderer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Pure compute (no UIKit/SceneKit). Safe to call from any thread/actor.
//

//
//  CumulusRenderer.swift
//  Glasslands
//
//  Pure compute – no UIKit/SceneKit. Safe to call from any actor.
//
//  Algorithm (high level)
//  1) Build a low‑res “puff” density field in lat‑long space + a zenith cap.
//  2) For each pixel of an equirectangular image: sample density, do soft
//     thresholding, estimate a normal from the field gradient, and shade
//     with one‑bounce ambient/forward‑scattering. Blend over a blue sky
//     gradient with horizon brightening. Simple integer dithering to avoid
//     banding.
//

import Foundation
import simd

struct CumulusPixels: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

struct CumulusRenderer {

    // MARK: - Public entry point

    /// Returns an RGBA8 equirectangular sky (2:1).
    static func computePixels(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = 0.34,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63
    ) -> CumulusPixels {

        let W = max(256, width)
        let H = max(128, height)

        // Low‑res fields (up‑sampled for shading).
        let FW = max(256, W / 2)
        let FH = max(128, H / 2)

        let baseField  = CloudFieldLL.build(width: FW, height: FH, coverage: coverage, seed: seed)
        let capField   = ZenithCapField.build(size: max(FW, FH), seed: seed, densityScale: 0.55)

        // Sun direction in world space (y up).
        let deg: Float = .pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        var sunDir = simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        )
        sunDir = simd_normalize(sunDir)

        // Sky gradient colours (sRGB).
        let SKY_TOP = simd_float3(0.30, 0.56, 0.96)  // deep zenith blue
        let SKY_MID = simd_float3(0.56, 0.74, 0.96)  // mid-sky
        let SKY_BOT = simd_float3(0.88, 0.93, 0.99)  // near horizon

        // Soft threshold controls the silhouette. Lower threshold -> more clouds.
        let thresh  = SkyMath.clampf(0.58 - 0.36 * coverage, 0.30, 0.70)
        let softness = SkyMath.clampf(edgeSoftness, 0.10, 0.35)

        // Helpers to sample the combined density and its gradient.
        @inline(__always)
        func dirFromUV(_ u: Float, _ v: Float) -> simd_float3 {
            // Equirectangular: u ∈ [0,1] -> az ∈ [-π,π], v ∈ [0,1] -> el ∈ [π/2,-π/2]
            let az = (u - 0.5) * (2.0 * .pi)
            let el = (.pi * (0.5 - v))
            return simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
        }

        @inline(__always)
        func skyBase(_ v: Float) -> simd_float3 {
            // V=0 top, 0.5 horizon, 1 bottom (nadir). Blend three-way with a mild S‑curve.
            let t = SkyMath.smooth01(v)
            let midBlend = SkyMath.smoothstep(0.18, 0.82, t)
            let topBlend = SkyMath.smoothstep(0.00, 0.42, t)
            let top = SKY_TOP
            let mid = SKY_MID
            let bot = SKY_BOT
            // Top->Mid->Bottom gradient.
            return SkyMath.mix3(SkyMath.mix3(top, mid, topBlend), bot, midBlend)
        }

        @inline(__always)
        func combinedDensity(u: Float, v: Float) -> Float {
            let dLL = baseField.sample(u: u, v: v)

            // Zenith cap – projected orthographically using the direction.
            let d = dirFromUV(u, v)
            let up = d.y
            // Fade in the cap near the zenith only.
            let capT = SkyMath.smoothstep(0.90, 0.985, up)
            let uc = (d.x * 0.5) + 0.5
            let vc = (d.z * 0.5) + 0.5
            let dCap = capField.sample(u: uc, v: vc) * capT

            return dLL + dCap
        }

        @inline(__always)
        func gradDensity(u: Float, v: Float) -> (Float, Float) {
            let du: Float = 1.0 / Float(FW)
            let dv: Float = 1.0 / Float(FH)
            let p  = combinedDensity(u: u, v: v)
            let px = combinedDensity(u: u + du, v: v)
            let py = combinedDensity(u: u, v: v + dv)
            return (px - p, py - p)
        }

        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        let invW = 1.0 / Float(W)
        let invH = 1.0 / Float(H)

        // UV step vector that roughly follows the sun on the lat‑long map.
        // This is only used for a cheap one‑bounce “self‑shadow” probe.
        let sunUV = simd_float2(
            sunDir.x * 0.035,     // x ~ azimuth
            -sunDir.y * 0.045     // y ~ elevation (v increases downward)
        )

        for j in 0..<H {
            for i in 0..<W {
                let u = (Float(i) + 0.5) * invW
                let v = (Float(j) + 0.5) * invH

                // Density and soft threshold (edge softening shapes big cotton puffs).
                let dens = combinedDensity(u: u, v: v)
                let t = (dens - thresh) / max(1e-5, softness)
                let alpha = SkyMath.smooth01(t)          // 0..1 mask

                // Gradient for a pseudo-normal (billowy lighting).
                let (gx, gy) = gradDensity(u: u, v: v)
                // Treat density as a height field with upward bias.
                let n = simd_normalize(simd_float3(-gx * 24, 1.6, -gy * 24))

                // Sun lighting with soft wrap to keep tops bright.
                let ndotl = max(0, simd_dot(n, sunDir))
                let wrap  = (ndotl + 0.25) / (1.0 + 0.25) // wrap diffuse
                var shade = 0.55 + 0.65 * wrap

                // One-bounce self‑shadow (very cheap, 3 taps).
                var occl: Float = 0
                var wSum: Float = 0
                var step: Float = 1
                for _ in 0..<3 {
                    let su = u - sunUV.x * step
                    let sv = v - sunUV.y * step
                    occl += combinedDensity(u: su, v: sv) * (0.50 / step)
                    wSum += (0.50 / step)
                    step += 1
                }
                occl = occl / max(1e-5, wSum)
                shade *= (1.0 - 0.55 * occl)

                // Silver lining on sunward edges (forward scattering).
                let dir = dirFromUV(u, v)
                let facing = max(0, simd_dot(dir, sunDir))
                let rim = powf(alpha * facing, 3.0)
                shade += 0.20 * rim

                // Base cloud albedo and subtle warm tint near sun.
                let sunWarm = simd_float3(1.0, 0.98, 0.96)
                let cloudWhite = simd_mix(simd_float3(repeating: 1.0), sunWarm, min(1.0, facing * 0.6))
                var cloudRGB = cloudWhite * shade

                // Slightly darker bottoms.
                let upness = dir.y
                let bottomDark = 0.08 * SkyMath.smoothstep(-0.1, 0.25, 0.25 - upness)
                cloudRGB *= (1.0 - bottomDark)

                // Background sky.
                var sky = skyBase(v)
                // Horizon brightening towards the sun.
                let horizonT = SkyMath.smoothstep(0.38, 0.62, v) // near equator
                sky = SkyMath.mix3(sky, simd_float3(1.0, 1.0, 1.0), 0.10 * horizonT * facing)

                // Composite.
                let outRGB = sky * (1.0 - alpha) + cloudRGB * alpha

                // Ordered-ish dithering to hide banding.
                let h = SkyMath.h2(Int32(i), Int32(j), seed)
                let dither = (Float(h & 255) / 255.0 - 0.5) * (1.0 / 255.0)

                let r = SkyMath.toByte(outRGB.x + dither)
                let g = SkyMath.toByte(outRGB.y + dither)
                let b = SkyMath.toByte(outRGB.z + dither)
                let a = UInt8(255)

                let idx = (j * W + i) * 4
                rgba[idx + 0] = r
                rgba[idx + 1] = g
                rgba[idx + 2] = b
                rgba[idx + 3] = a
            }
        }

        return CumulusPixels(width: W, height: H, rgba: rgba)
    }
}
