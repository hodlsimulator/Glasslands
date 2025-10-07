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
    var params4     : SIMD4<Float>  // x=puffStrength, y=quality
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
            params1:     SIMD4(1400, 0.60, 1.20, 0.70), // coverage↑, density↑, steps↓
            params2:     SIMD4(0.60, 1.60, 0.10, 0.90), // powder↓, horizon↓, detail↓
            params3:     SIMD4(0, 0, 0, 0.0048),
            params4:     SIMD4(0.62, 0.45, 0, 0)        // puffStrength, quality fixed fast
        )
    }

    func snapshot() -> GLCloudUniforms {
        os_unfair_lock_lock(&lock); let out = u; os_unfair_lock_unlock(&lock); return out
    }

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
}
