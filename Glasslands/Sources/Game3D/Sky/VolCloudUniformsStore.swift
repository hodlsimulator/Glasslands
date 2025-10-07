//
//  VolCloudUniformsStore.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Thread-safe uniform store for volumetric clouds. Main thread updates; render thread reads.
//

import simd
import os

struct GLCloudUniforms {
    var sunDirWorld : SIMD4<Float>
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float>  // x=time, y=wind.x, z=wind.y, w=baseY
    var params1     : SIMD4<Float>  // x=topY, y=coverage, z=densityMul, w=stepMul
    var params2     : SIMD4<Float>  // x=mieG, y=powderK, z=horizonLift, w=detailMul
    var params3     : SIMD4<Float>  // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    var params4     : SIMD4<Float>  // x=puffStrength, y=quality(fixed), z=macroScale, w=macroThreshold
}

final class VolCloudUniformsStore {
    static let shared = VolCloudUniformsStore()

    private var u: GLCloudUniforms
    private var lock = os_unfair_lock_s()

    private init() {
        u = GLCloudUniforms(
            sunDirWorld: SIMD4(0, 1, 0, 0),
            sunTint:     SIMD4(1, 1, 1, 0),
            params0:     SIMD4(0, 0.60, 0.20, 400),
            // ↓ scattered cumulus defaults
            params1:     SIMD4(1400, 0.32, 1.10, 0.70),  // topY, coverage, densityMul, stepMul
            params2:     SIMD4(0.60, 1.40, 0.10, 0.90),  // mieG, powderK, horizonLift, detailMul
            params3:     SIMD4(0, 0, 0, 0.0048),         // puffScale
            params4:     SIMD4(0.62, 0.45, 0.00035, 0.58) // puffStrength, quality, macroScale, macroThresh
        )
    }

    func snapshot() -> GLCloudUniforms {
        os_unfair_lock_lock(&lock); let out = u; os_unfair_lock_unlock(&lock); return out
    }

    // Fast path: only update time, sun, wind, domain offset per frame.
    func update(time: Float,
                sunDirWorld: SIMD3<Float>,
                wind: SIMD2<Float>,
                domainOffset: SIMD2<Float>)
    {
        os_unfair_lock_lock(&lock)
        u.sunDirWorld = SIMD4(simd_normalize(sunDirWorld), 0)
        u.params0.x = time
        u.params0.y = wind.x
        u.params0.z = wind.y
        u.params3.x = domainOffset.x
        u.params3.y = domainOffset.y
        os_unfair_lock_unlock(&lock)
    }

    // Optional knobs to tweak fill later:
    // func setCoverage(_ c: Float) { os_unfair_lock_lock(&lock); u.params1.y = max(0, min(0.95, c)); os_unfair_lock_unlock(&lock) }
    // func setMacro(scale: Float, threshold: Float) { os_unfair_lock_lock(&lock); u.params4.z = max(1e-6, scale); u.params4.w = max(0, min(1, threshold)); os_unfair_lock_unlock(&lock) }
}
