//
//  CumulusRenderer.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Algorithm (high level)
//  1) Build a low-res “puff” density field in lat-long space + a zenith cap.
//  2) For each pixel of an equirectangular image: sample density, do soft
//     thresholding, estimate a normal from the field gradient, and shade
//     with one-bounce ambient/forward-scattering. Blend over a blue sky
//     gradient with horizon brightening. Simple integer dithering to avoid
//     banding.
//

import Foundation
import simd

public struct CumulusPixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
}

/// Free function version to avoid any accidental global‑actor inference.
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

    // Low‑res fields (up‑sampled for shading).
    let FW = max(256, W / 2)
    let FH = max(128, H / 2)
    let baseField = CloudFieldLL.build(width: FW, height: FH, coverage: coverage, seed: seed)
    let capField  = ZenithCapField.build(size: max(FW, FH), seed: seed, densityScale: 0.55)

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
    let SKY_TOP = simd_float3(0.30, 0.56, 0.96) // deep zenith blue
    let SKY_MID = simd_float3(0.56, 0.74, 0.96) // mid‑sky
    let SKY_BOT = simd_float3(0.88, 0.93, 0.99) // near horizon

    // Silhouette controls.
    let thresh   = SkyMath.clampf(0.58 - 0.36 * coverage, 0.30, 0.70)
    let softness = SkyMath.clampf(edgeSoftness, 0.10, 0.35)

    // Helpers to go from (u,v) to world direction and back.
    @inline(__always)
    func dirFromUV(_ u: Float, _ v: Float) -> simd_float3 {
        // Equirectangular: u ∈ [0,1] → az ∈ [-π,π], v ∈ [0,1] → el ∈ [π/2, -π/2]
        let az = (u - 0.5) * (2.0 * .pi)
        let el = (.pi * (0.5 - v))
        return simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
    }

    /// Smooth three‑stop blue gradient; v=0 top, 0.5 horizon, 1 nadir.
    @inline(__always)
    func skyBase(_ v: Float) -> simd_float3 {
        let t = SkyMath.smooth01(v)
        let midBlend = SkyMath.smoothstep(0.18, 0.82, t)
        let topBlend = SkyMath.smoothstep(0.00, 0.42, t)
        return SkyMath.mix3(SkyMath.mix3(SKY_TOP, SKY_MID, topBlend), SKY_BOT, midBlend)
    }

    /// Combined cloud density from the lat‑long field and the zenith cap.
    @inline(__always)
    func combinedDensity(u: Float, v: Float) -> Float {
        let dLL = baseField.sample(u: u, v: v)

        // Zenith cap – project orthographically using the viewing direction.
        let d = dirFromUV(u, v)
        let up = d.y

        // Fade in the cap only very close to the zenith so it never forms a ring.
        let capT = SkyMath.smoothstep(0.90, 0.985, up)

        // Orthographic projection of the direction onto the unit disc.
        let uc = (d.x * 0.5) + 0.5
        let vc = (d.z * 0.5) + 0.5
        let dCap = capField.sample(u: uc, v: vc) * capT

        return dLL + dCap
    }

    /// Gradient of the combined density in UV space.
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

    // UV step that roughly follows the sun on the lat‑long map, for the
    // cheap one‑bounce “self‑shadow” probe below.
    let sunUV = simd_float2(
        sunDir.x * 0.035,      // x ~ azimuth
        -sunDir.y * 0.045      // y ~ elevation (v increases downward)
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

            // Early out → pure sky pixel.
            if a <= 1e-4 {
                let idx = (j * W + i) << 2
                rgba[idx + 0] = SkyMath.toByte(base.x)
                rgba[idx + 1] = SkyMath.toByte(base.y)
                rgba[idx + 2] = SkyMath.toByte(base.z)
                rgba[idx + 3] = 255
                continue
            }

            // 2) Gradient → approximate normal in world space.
            // Tangent basis at (u,v).
            let az = (u - 0.5) * (2.0 * .pi)
            let el = (.pi * (0.5 - v))
            let ca = cosf(az), sa = sinf(az)
            let ce = cosf(el), se = sinf(el)

            // World direction for this pixel.
            let viewDir = simd_float3(sa * ce, se, ca * ce)

            // ∂dir/∂az and ∂dir/∂el (scaled—but we normalise later).
            let dAz = simd_float3(ca * ce, 0, -sa * ce)      // tangent along azimuth
            let dEl = simd_float3(-sa * se, ce, -ca * se)    // tangent along elevation
            let T_u = simd_normalize(dAz)
            let T_v = simd_normalize(dEl)

            let (gx, gy) = gradDensity(u: u, v: v)
            // Scale balances "puffing" vs. flatness.
            let gradScale: Float = 2.1
            // Blend between viewDir and gradient‑displaced normal.
            var n = simd_normalize(viewDir - gradScale * (gx * T_u + gy * T_v))
            // Ensure normal faces outward (towards the camera sphere).
            if simd_dot(n, viewDir) < 0 { n = -n }

            // 3) Lighting: ambient + lambert + forward‑scattering “silver lining”.
            let lambert = max(0, simd_dot(n, sunDir))

            // Forward scattering: bright rim when looking towards the sun.
            let mu = max(0, simd_dot(viewDir, sunDir))      // cos(scatter angle)
            let silver = powf(mu, 8.0) * 0.65               // tight and bright near sun

            // Cheap self‑shadow: sample density up‑sun; more density → darker.
            let uS = u - sunUV.x
            let vS = v - sunUV.y
            let dS = combinedDensity(u: uS, v: vS)
            let occl = SkyMath.clampf(1.0 - (dS - d) * 1.35, 0.2, 1.0)

            // Horizon brightening helps the perspective feel near the bottom.
            let horizon = SkyMath.smoothstep(0.46, 0.70, v)

            // Compose cloud colour (sRGB). Keep it white but softly shaded.
            var intensity = 0.52                                 // base ambient
            intensity += 0.45 * lambert * occl                   // lit faces
            intensity += 0.18 * silver                           // silver lining
            intensity += 0.10 * horizon                          // subtle uplift near horizon
            intensity = min(intensity, 1.05)

            var cloud = simd_float3(repeating: intensity)

            // 4) Alpha blend over sky.
            var rgb = base * (1.0 - a) + cloud * a

            // 5) Tiny ordered dither to avoid banding on low‑bit displays.
            let h = SkyMath.h2(Int32(i), Int32(j), seed) & 0xFF
            let dither = (Float(h) * (1.0 / 255.0) - 0.5) * (1.0 / 255.0)
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
