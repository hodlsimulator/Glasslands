//
//  VolCloudUniformsStore.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Thread-safe live uniforms for the volumetric vapour shader (Metal).
//  Adds a configure(...) API so gameplay code can choose "scattered cumulus" easily.
//

import simd
import os

public struct GLCloudUniforms {
    public var sunDirWorld : SIMD4<Float>
    public var sunTint     : SIMD4<Float>
    public var params0     : SIMD4<Float> // x=time, y=wind.x, z=wind.y, w=baseY
    public var params1     : SIMD4<Float> // x=topY, y=coverage, z=densityMul, w=stepMul
    public var params2     : SIMD4<Float> // x=mieG, y=powderK, z=horizonLift, w=detailMul
    public var params3     : SIMD4<Float> // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    public var params4     : SIMD4<Float> // x=puffStrength, y=quality(fixed fast), z=macroScale, w=macroThreshold
}

public final class VolCloudUniformsStore {
    public static let shared = VolCloudUniformsStore()

    private var u: GLCloudUniforms
    private var lock = os_unfair_lock_s()

    private init() {
        // Scattered, bright cumulus defaults
        u = GLCloudUniforms(
            sunDirWorld: SIMD4<Float>(0, 1, 0, 0),
            sunTint:     SIMD4<Float>(1, 1, 1, 0),
            params0:     SIMD4<Float>(0, 0.60, 0.20, 400),     // time, wind.x, wind.y, baseY
            params1:     SIMD4<Float>(1400, 0.34, 1.10, 0.70), // topY, coverage, densityMul, stepMul
            params2:     SIMD4<Float>(0.60, 1.40, 0.10, 0.90), // mieG, powderK, horizonLift, detailMul
            params3:     SIMD4<Float>(0, 0, 0, 0.0048),        // domainOffX, domainOffY, rotate, puffScale
            params4:     SIMD4<Float>(0.62, 0.45, 0.00035, 0.58) // puffStrength, quality, macroScale, macroThreshold
        )
    }

    public func snapshot() -> GLCloudUniforms {
        os_unfair_lock_lock(&lock); let out = u; os_unfair_lock_unlock(&lock); return out
    }

    // Fast per-frame update from the render clock.
    public func update(time: Float, sunDirWorld: SIMD3<Float>, wind: SIMD2<Float>, domainOffset: SIMD2<Float>) {
        os_unfair_lock_lock(&lock)
        u.sunDirWorld = SIMD4(simd_normalize(sunDirWorld), 0)
        u.params0.x = time
        u.params0.y = wind.x
        u.params0.z = wind.y
        u.params3.x = domainOffset.x
        u.params3.y = domainOffset.y
        os_unfair_lock_unlock(&lock)
    }

    // One-shot setup for a "scattered cumulus" look using volumetric vapour.
    public func configure(
        baseY: Float,
        topY: Float,
        coverage: Float,
        densityMul: Float,
        stepMul: Float,
        horizonLift: Float,
        detailMul: Float,
        puffScale: Float,
        puffStrength: Float,
        macroScale: Float,
        macroThreshold: Float
    ) {
        os_unfair_lock_lock(&lock)
        u.params0.w = baseY
        u.params1.x = topY
        u.params1.y = max(0, min(0.95, coverage))
        u.params1.z = max(0, densityMul)
        u.params1.w = max(0.35, min(1.25, stepMul))
        u.params2.z = max(0, min(1, horizonLift))
        u.params2.w = detailMul
        u.params3.w = max(1e-4, puffScale)
        u.params4.x = max(0, puffStrength)
        u.params4.z = max(1e-6, macroScale)
        u.params4.w = max(0, min(1, macroThreshold))
        os_unfair_lock_unlock(&lock)
    }
}
