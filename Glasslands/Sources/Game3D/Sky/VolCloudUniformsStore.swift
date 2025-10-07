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
    var params4     : SIMD4<Float>  // x=puffStrength, y/z/w unused
}

final class VolCloudUniformsStore {
    static let shared = VolCloudUniformsStore()

    private var u: GLCloudUniforms
    private var lock = os_unfair_lock_s()

    private init() {
        u = GLCloudUniforms(
            sunDirWorld: SIMD4(0, 1, 0, 0),
            sunTint:     SIMD4(1, 1, 1, 0),
            params0:     SIMD4(0, 0.60, 0.20, 400),     // time, wind.x, wind.y, baseY
            params1:     SIMD4(1400, 0.50, 1.15, 0.85), // topY, coverage, densityMul, stepMul
            params2:     SIMD4(0.60, 2.10, 0.14, 1.10), // mieG, powderK, horizonLift, detailMul
            params3:     SIMD4(0, 0, 0, 0.0045),        // domainOffX, domainOffY, domainRotate, puffScale
            params4:     SIMD4(0.65, 0, 0, 0)           // puffStrength
        )
    }

    func snapshot() -> GLCloudUniforms {
        os_unfair_lock_lock(&lock)
        let out = u
        os_unfair_lock_unlock(&lock)
        return out
    }

    // Main-thread updates (call from your frame tick / main actor code).
    func update(time: Float,
                sunDirWorld: SIMD3<Float>,
                wind: SIMD2<Float>,
                domainOffset: SIMD2<Float>,
                domainRotate: Float,
                baseY: Float,
                topY: Float,
                coverage: Float,
                densityMul: Float,
                stepMul: Float,
                mieG: Float,
                powderK: Float,
                horizonLift: Float,
                detailMul: Float,
                puffScale: Float,
                puffStrength: Float)
    {
        os_unfair_lock_lock(&lock)
        u.sunDirWorld = SIMD4(simd_normalize(sunDirWorld), 0)
        u.sunTint     = SIMD4(1, 1, 1, 0)
        u.params0     = SIMD4(time, wind.x, wind.y, baseY)
        u.params1     = SIMD4(topY, coverage, max(0, densityMul), max(0.25, stepMul))
        u.params2     = SIMD4(mieG, max(0, powderK), horizonLift, max(0, detailMul))
        u.params3     = SIMD4(domainOffset.x, domainOffset.y, domainRotate, max(0.0001, puffScale))
        u.params4     = SIMD4(max(0, puffStrength), 0, 0, 0)
        os_unfair_lock_unlock(&lock)
    }
}
