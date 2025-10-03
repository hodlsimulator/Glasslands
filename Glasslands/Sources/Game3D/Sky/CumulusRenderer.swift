//
//  CumulusRenderer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Equirectangular cumulus renderer with true “pile-of-balls” clusters,
//  softer thresholds, reduced zenith ring bias, and tuned shading.
//

import Foundation
import simd

public struct CumulusPixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
}

public func computeCumulusPixels(
    width: Int = 1536,
    height: Int = 768,
    coverage: Float = 0.38,
    edgeSoftness: Float = 0.22,
    seed: UInt32 = 424242,
    sunAzimuthDeg: Float = 35,
    sunElevationDeg: Float = 63
) -> CumulusPixels {

    let W = max(256, width)
    let H = max(128, height)

    let FW = max(256, W / 2)
    let FH = max(128, H / 2)
    let baseField = CloudFieldLL.build(width: FW, height: FH, coverage: coverage, seed: seed)
    // Much lighter cap to avoid arcs.
    let capField  = ZenithCapField.build(size: max(FW, FH), seed: seed, densityScale: 0.35)

    // Sun direction
    let deg: Float = Float.pi / 180.0
    let sunAz = sunAzimuthDeg * deg
    let sunEl = sunElevationDeg * deg
    var sunDir = simd_float3(
        sinf(sunAz) * cosf(sunEl),
        sinf(sunEl),
        cosf(sunAz) * cosf(sunEl)
    )
    sunDir = simd_normalize(sunDir)

    // Sky gradient colours (sRGB).
    let SKY_TOP = simd_float3(0.30 as Float, 0.56 as Float, 0.96 as Float)
    let SKY_MID = simd_float3(0.56 as Float, 0.74 as Float, 0.96 as Float)
    let SKY_BOT = simd_float3(0.88 as Float, 0.93 as Float, 0.99 as Float)

    // Thresholding tuned for fluffy silhouettes.
    let thresh   = SkyMath.clampf(0.60 - 0.32 * coverage, 0.28, 0.66)
    let softness = SkyMath.clampf(edgeSoftness, 0.14, 0.30)

    @inline(__always)
    func dirFromUV(_ u: Float, _ v: Float) -> simd_float3 {
        let az = (u - 0.5 as Float) * (2.0 as Float * Float.pi)
        let el = Float.pi * (0.5 as Float - v)
        return simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
    }

    @inline(__always)
    func skyBase(_ v: Float) -> simd_float3 {
        // Slightly deeper top blue than before; brighter near horizon.
        let t = SkyMath.smooth01(v)
        let midBlend = SkyMath.smoothstep(0.18, 0.82, t)
        let topBlend = SkyMath.smoothstep(0.00, 0.40, t)
        return SkyMath.mix3(SkyMath.mix3(SKY_TOP, SKY_MID, topBlend), SKY_BOT, midBlend)
    }

    @inline(__always)
    func combinedDensity(u: Float, v: Float) -> Float {
        let dLL = baseField.sample(u: u, v: v)
        let d = dirFromUV(u, v)
        let up = d.y
        // Cap fades in only very close to zenith.
        let capT = SkyMath.smoothstep(0.92 as Float, 0.988 as Float, up)
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

    // Up-sun probe for occlusion.
    let sunUV = simd_float2(
        sunDir.x * (0.030 as Float),
        -sunDir.y * (0.040 as Float)
    )

    for j in 0..<H {
        let v = Float(j) * invH
        let base = skyBase(v)

        for i in 0..<W {
            let u = Float(i) * invW

            let d = combinedDensity(u: u, v: v)
            let a = SkyMath.smoothstep(thresh - softness, thresh + softness, d)

            if a <= 1e-4 {
                let idx = (j * W + i) << 2
                rgba[idx + 0] = SkyMath.toByte(base.x)
                rgba[idx + 1] = SkyMath.toByte(base.y)
                rgba[idx + 2] = SkyMath.toByte(base.z)
                rgba[idx + 3] = 255
                continue
            }

            // Tangent basis and gradients.
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
            // Gentler gradient scale prevents streaking.
            let gradScale: Float = 1.35
            var n = simd_normalize(viewDir - gradScale * (gx * T_u + gy * T_v))
            if simd_dot(n, viewDir) < 0 { n = -n }

            // Lighting.
            let lambert = max(0.0 as Float, simd_dot(n, sunDir))
            let mu = max(0.0 as Float, simd_dot(viewDir, sunDir))
            // Slightly wider forward-scatter lobe for fluffy brilliance.
            let silver = powf(mu, 6.0 as Float) * (0.55 as Float)

            // Self-shadow.
            let uS = u - sunUV.x
            let vS = v - sunUV.y
            let dS = combinedDensity(u: uS, v: vS)
            let occl = SkyMath.clampf(1.0 as Float - (dS - d) * (1.25 as Float), 0.25 as Float, 1.0 as Float)

            // Horizon boost (perspective cue).
            let horizon = SkyMath.smoothstep(0.48 as Float, 0.70 as Float, v)

            var intensity = 0.52 as Float
            intensity += (0.48 as Float) * lambert * occl
            intensity += (0.20 as Float) * silver
            intensity += (0.08 as Float) * horizon
            let maxI: Float = 1.06
            intensity = min(intensity, maxI)

            let cloud = simd_float3(repeating: intensity)

            var rgb = base * (1.0 as Float - a) + cloud * a

            // Ordered dither
            let h = SkyMath.h2(Int32(i), Int32(j), seed) & 0xFF
            let inv255: Float = 1.0 / 255.0
            let dither = (Float(h) * inv255 - 0.5 as Float) * inv255
            rgb += simd_float3(repeating: dither)

            let idx = (j * W + i) << 2
            rgba[idx + 0] = SkyMath.toByte(rgb.x)
            rgba[idx + 1] = SkyMath.toByte(rgb.y)
            rgba[idx + 2] = SkyMath.toByte(rgb.z)
            rgba[idx + 3] = 255
        }
    }

    return CumulusPixels(width: W, height: H, rgba: rgba)
}
