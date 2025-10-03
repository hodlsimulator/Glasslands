//
//  CumulusRenderer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Equirectangular cumulus renderer. Float-only math and literals so Swift
//  doesn’t try to upcast to Double. No UI types here (keeps it actor-agnostic).
//

import Foundation
import simd

public struct CumulusPixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
}

// Free function (not actor-isolated by type).
public func computeCumulusPixels(
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

    // Low-res fields (up-sampled for shading).
    let FW = max(256, W / 2)
    let FH = max(128, H / 2)
    let baseField = CloudFieldLL.build(width: FW, height: FH, coverage: coverage, seed: seed)
    let capField  = ZenithCapField.build(size: max(FW, FH), seed: seed, densityScale: 0.55)

    // Sun direction (y up).
    let deg: Float = Float.pi / 180.0
    let sunAz = sunAzimuthDeg * deg
    let sunEl = sunElevationDeg * deg
    var sunDir = simd_float3(
        sinf(sunAz) * cosf(sunEl),
        sinf(sunEl),
        cosf(sunAz) * cosf(sunEl)
    )
    sunDir = simd_normalize(sunDir)

    // Sky gradient (sRGB) — explicitly Float.
    let SKY_TOP = simd_float3(0.30 as Float, 0.56 as Float, 0.96 as Float)
    let SKY_MID = simd_float3(0.56 as Float, 0.74 as Float, 0.96 as Float)
    let SKY_BOT = simd_float3(0.88 as Float, 0.93 as Float, 0.99 as Float)

    // Silhouette controls.
    let thresh   = SkyMath.clampf(0.58 - 0.36 * coverage, 0.30, 0.70)
    let softness = SkyMath.clampf(edgeSoftness, 0.10, 0.35)

    // Helpers.
    @inline(__always)
    func dirFromUV(_ u: Float, _ v: Float) -> simd_float3 {
        // u ∈ [0,1] → az ∈ [-π,π], v ∈ [0,1] → el ∈ [π/2, -π/2]
        let az = (u - 0.5 as Float) * (2.0 as Float * Float.pi)
        let el = Float.pi * (0.5 as Float - v)
        return simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
    }

    @inline(__always)
    func skyBase(_ v: Float) -> simd_float3 {
        let t = SkyMath.smooth01(v)
        let midBlend = SkyMath.smoothstep(0.18, 0.82, t)
        let topBlend = SkyMath.smoothstep(0.00, 0.42, t)
        return SkyMath.mix3(SkyMath.mix3(SKY_TOP, SKY_MID, topBlend), SKY_BOT, midBlend)
    }

    @inline(__always)
    func combinedDensity(u: Float, v: Float) -> Float {
        let dLL = baseField.sample(u: u, v: v)

        // Zenith cap.
        let d = dirFromUV(u, v)
        let up = d.y
        let capT = SkyMath.smoothstep(0.90 as Float, 0.985 as Float, up)

        // Orthographic projection of the direction onto the unit disc.
        let uc = (d.x * 0.5 as Float) + 0.5 as Float
        let vc = (d.z * 0.5 as Float) + 0.5 as Float
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
    let invW: Float = 1.0 / Float(W)
    let invH: Float = 1.0 / Float(H)

    // UV step for cheap up-sun occlusion probe.
    let sunUV = simd_float2(
        sunDir.x * (0.035 as Float),     // azimuth
        -sunDir.y * (0.045 as Float)     // elevation (v increases downward)
    )

    // Render.
    for j in 0..<H {
        let v = Float(j) * invH
        let base = skyBase(v)

        for i in 0..<W {
            let u = Float(i) * invW

            // 1) Density and soft threshold → alpha.
            let d = combinedDensity(u: u, v: v)
            let a = SkyMath.smoothstep(thresh - softness, thresh + softness, d)

            // Pure sky.
            if a <= 1e-4 {
                let idx = (j * W + i) << 2
                rgba[idx + 0] = SkyMath.toByte(base.x)
                rgba[idx + 1] = SkyMath.toByte(base.y)
                rgba[idx + 2] = SkyMath.toByte(base.z)
                rgba[idx + 3] = 255
                continue
            }

            // 2) Gradient → approximate normal in world space.
            let az = (u - 0.5 as Float) * (2.0 as Float * Float.pi)
            let el = Float.pi * (0.5 as Float - v)
            let ca = cosf(az), sa = sinf(az)
            let ce = cosf(el), se = sinf(el)

            let viewDir = simd_float3(sa * ce, se, ca * ce)

            let dAz = simd_float3(ca * ce, 0, -sa * ce)
            let dEl = simd_float3(-sa * se, ce, -ca * se)
            let T_u = simd_normalize(dAz)
            let T_v = simd_normalize(dEl)

            let (gx, gy) = gradDensity(u: u, v: v)
            let gradScale: Float = 2.1
            var n = simd_normalize(viewDir - gradScale * (gx * T_u + gy * T_v))
            if simd_dot(n, viewDir) < 0 { n = -n }

            // 3) Lighting.
            let lambert = max(0.0 as Float, simd_dot(n, sunDir))

            // Forward scattering.
            let mu = max(0.0 as Float, simd_dot(viewDir, sunDir))
            let silver = powf(mu, 8.0 as Float) * (0.65 as Float)

            // Cheap self-shadow.
            let uS = u - sunUV.x
            let vS = v - sunUV.y
            let dS = combinedDensity(u: uS, v: vS)
            let occl = SkyMath.clampf(1.0 as Float - (dS - d) * (1.35 as Float), 0.2 as Float, 1.0 as Float)

            // Horizon brightening.
            let horizon = SkyMath.smoothstep(0.46 as Float, 0.70 as Float, v)

            // Compose.
            var intensity = 0.52 as Float
            intensity += (0.45 as Float) * lambert * occl
            intensity += (0.18 as Float) * silver
            intensity += (0.10 as Float) * horizon
            let maxIntensity: Float = 1.05
            intensity = min(intensity, maxIntensity)

            let cloud = simd_float3(repeating: intensity)

            // 4) Alpha blend over sky.
            var rgb = base * (1.0 as Float - a) + cloud * a

            // 5) Tiny ordered dither to avoid banding.
            let h = SkyMath.h2(Int32(i), Int32(j), seed) & 0xFF
            let inv255: Float = 1.0 / 255.0
            let dither = (Float(h) * inv255 - 0.5 as Float) * inv255
            rgb += simd_float3(repeating: dither)

            // Store.
            let idx = (j * W + i) << 2
            rgba[idx + 0] = SkyMath.toByte(rgb.x)
            rgba[idx + 1] = SkyMath.toByte(rgb.y)
            rgba[idx + 2] = SkyMath.toByte(rgb.z)
            rgba[idx + 3] = 255
        }
    }

    return CumulusPixels(width: W, height: H, rgba: rgba)
}
