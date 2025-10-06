//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Sun + shadow diffusion driven by cloud occlusion ALONG THE SUN DIRECTION.
//  Combines a directional sample from the lat-long cloud field with billboard overlap,
//  then maps that to direct light, shadow softness/contrast, sky-fill, and IBL intensity.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    // Cache the lat-long cloud field so we can sample it every frame cheaply.
    private struct _LLCache {
        var field: CloudFieldLL
        var seed: UInt32
        var coverage: Float
        var width: Int
        var height: Int
    }
    private static var _cloudLL: _LLCache?

    /// Per-frame: modulates direct sun, shadows, directional sky-fill, and IBL by cloud occlusion.
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // 1) How much is the SUN covered right now? (0 = clear, 1 = thick cloud on the sun)
        let D_bill = estimateBillboardOcclusionOnSun()              // from sprites (fast)
        let D_ll   = estimateLatLongOcclusionOnSun()                // from sky field (directional)
        let D_now  = max(0.0, min(1.0, 1.0 - (1.0 - D_bill) * (1.0 - D_ll))) // union

        // 2) Smooth so thin wisps don’t flicker. Faster when clearing.
        let T_now: CGFloat = 1.0 - CGFloat(D_now)                   // transmittance
        let T_prev = (sunNode.value(forKey: "GL_prevTransmittance") as? CGFloat) ?? T_now
        let k = (T_now >= T_prev) ? 0.45 : 0.14
        let T = T_prev + (T_now - T_prev) * k
        sunNode.setValue(T, forKey: "GL_prevTransmittance")

        let D = max(0.0, 1.0 - T)                                   // diffusion 0…1

        // ---------- Lighting responses ----------
        // Direct sun: full when clear; falls off hard when covered.
        let baseIntensity: CGFloat = 1500
        // Give a tiny floor so it never goes pitch black.
        sun.intensity = baseIntensity * max(0.06, T)

        // Shadow shape: crisp when clear, soft when covered.
        let clearRadius: CGFloat  = 0.35
        let cloudyRadius: CGFloat = 12.0
        sun.shadowRadius = clearRadius + (cloudyRadius - clearRadius) * CGFloat(D)
        sun.shadowSampleCount = max(1, Int(round(2 + D * 14))) // 2…16

        // Shadow contrast: noticeably darker when clear; much lighter under cloud (but never gone).
        let alphaClear: CGFloat  = 0.78
        let alphaCloudy: CGFloat = 0.12
        let a = alphaClear + (alphaCloudy - alphaClear) * CGFloat(D)
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // Directional sky fill (no shadows): lifts the “back side” under cloud without flattening in clear sun.
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            // Gentle curve so it ramps in smoothly.
            let Dp = pow(D, 0.85)
            let minFill: CGFloat = 12     // clear
            let maxFill: CGFloat = 520    // thick cloud
            skyFill.intensity = minFill + (maxFill - minFill) * Dp
        }

        // IBL / environment intensity: subtle in clear, stronger under cloud.
        let baseIBL: CGFloat = 0.12
        let maxIBL:  CGFloat = 0.95
        scene.lightingEnvironment.intensity = baseIBL + (maxIBL - baseIBL) * CGFloat(pow(D, 0.9))

        // HDR sun halo: visible only when the sun is actually behind cloud.
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * CGFloat(D)
            halo.isHidden = D <= 1e-3
        }
    }

    // MARK: - Occlusion: Billboard sprites (camera → sun angular overlap)
    @MainActor
    private func estimateBillboardOcclusionOnSun() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Solar core radius (radians). Authoring uses ~6° diameter for the stylised sun.
        let sunR: Float = degreesToRadians(6.0) * 0.5
        let feather: Float = 0.35 * (.pi / 180.0)

        var oneMinus: Float = 1.0

        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)

            // Angular separation between sun and puff centre.
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            guard let sprite = bb.childNodes.first,
                  let plane = sprite.geometry as? SCNPlane else { continue }

            let dist: Float = simd_length(bp - cam)
            if dist <= 1e-3 { continue }

            // Apparent angular radius of the puff.
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.50) / max(1e-3, dist)) // ↑ a bit wider so puffs matter

            // Overlap in angular space.
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { continue }

            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))

            // Weight: opacity × gentle size emphasis × soft power for smoothness.
            let sizeW: Float = size / (size + 45.0)
            t = powf(t, 0.80) * Float(bb.opacity) * sizeW

            // Non-saturating union: 1 − ∏(1 − t_i)
            oneMinus *= max(0.0, 1.0 - min(0.98, t))
            if oneMinus <= 1e-4 { return 1.0 }
        }

        let cov = 1.0 - oneMinus
        return (cov < 0.01) ? 0.0 : min(1.0, cov)
    }

    // MARK: - Occlusion: Lat–long sky field sample at the sun’s direction
    // Uses the same low-level field the sky builds (clusters in equirect space),
    // rotated by the cloud layer’s yaw so we hit the correct bit of sky.
    // This gives a strong “sun behind cloud” signal even when billboards are sparse overhead.
    @MainActor
    private func estimateLatLongOcclusionOnSun() -> Float {
        // 1) Get or build the cached field using the current seed + coverage.
        let (seed, cov) = currentSkySeedAndCoverage()
        let W = 512, H = 256
        if let c = Self._cloudLL, c.seed == seed, abs(c.coverage - cov) < 1e-5, c.width == W, c.height == H {
            // ok
        } else {
            let field = CloudFieldLL.build(width: W, height: H, coverage: cov, seed: seed)
            Self._cloudLL = _LLCache(field: field, seed: seed, coverage: cov, width: W, height: H)
        }
        guard let cache = Self._cloudLL else { return 0.0 }

        // 2) Sun direction in the CLOUD LAYER’S local frame (undo the layer’s yaw).
        let sunW = simd_normalize(sunDirWorld)
        let yaw = (cloudLayerNode?.presentation.eulerAngles.y ?? 0)
        let cy = cosf(-yaw), sy = sinf(-yaw)
        let sunLocal = simd_float3(
            sunW.x * cy - sunW.z * sy,
            sunW.y,
            sunW.x * sy + sunW.z * cy
        )

        // 3) Map to equirect (u: 0..1 around Y, v: 0 top..1 bottom).
        let u = (atan2f(sunLocal.z, sunLocal.x) / (2.0 * .pi)) + 0.5
        let v = acosf(max(-1, min(1, sunLocal.y))) / .pi

        // 4) Sample field and map to a punchier occlusion for the solar disc.
        let f = cache.field.sample(u: u, v: v)  // 0…1-ish luma at that sky dir
        // Push small values down and ramp up fast under thicker clumps.
        let D = max(0.0, min(1.0, (f - 0.18) / 0.55))
        return D
    }

    // Read current seed and coverage used by the sky.
    @MainActor
    private func currentSkySeedAndCoverage() -> (UInt32, Float) {
        var cov: Float = 0.42 // default in VolumetricCloudProgram
        if let vol = scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: true)?
            .geometry?.firstMaterial,
           let cg = vol.value(forKey: "coverage") as? CGFloat {
            cov = Float(cg)
        }
        // cloudSeed is set in resetWorld(), reused by cloud field + billboards.
        return (cloudSeed, cov)
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
