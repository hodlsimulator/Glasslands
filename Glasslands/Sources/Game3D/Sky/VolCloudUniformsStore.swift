//
//  VolCloudUniformsStore.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Stores the procedural volumetric-cloud parameter pack used by:
//  - CloudShadowMap.metal (cloud shadows sweeping over terrain)
//  - optional volumetric sky cloud layers
//

import Foundation
import simd

actor VolCloudUniformsStore {

    static let shared = VolCloudUniformsStore()

    struct Snapshot {
        var params1: simd_float4
        var params2: simd_float4
        var params3: simd_float4
        var params4: simd_float4
        var wind: simd_float4
        var time: Float
    }

    // params1: topY, coverage, densityMul, stepMul
    // params2: mieG, powderK, horizonLift, detailMul
    // params3: domainOffX, domainOffY, rotate, puffScale
    // params4: puffStrength, quality, macroScale, macroThreshold
    private var params1 = simd_float4(1400, 0.46, 1.25, 0.82)
    private var params2 = simd_float4(0.60, 1.40, 0.10, 0.90)
    private var params3 = simd_float4(0, 0, 0, 0.0046)
    private var params4 = simd_float4(0.70, 0.45, 0.00042, 0.62)

    private var wind = simd_float4(0.45, 0.0, 0.18, 0.0) // xz = wind direction, z = speed scale
    private var time: Float = 0

    func configure(
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
        params1 = simd_float4(topY, coverage, densityMul, stepMul)
        params2.z = horizonLift
        params2.w = detailMul
        params3.w = puffScale
        params4.x = puffStrength
        params4.z = macroScale
        params4.w = macroThreshold
    }

    func setWind(directionXZ: simd_float2, speed: Float) {
        wind.x = directionXZ.x
        wind.y = directionXZ.y
        wind.z = speed
    }

    func advance(dt: Float) {
        time += dt
        params3.x += wind.x * wind.z * dt
        params3.y += wind.y * wind.z * dt

        // Gentle slow rotation to keep the pattern alive.
        params3.z += 0.01 * dt
    }

    func snapshot() -> Snapshot {
        Snapshot(params1: params1, params2: params2, params3: params3, params4: params4, wind: wind, time: time)
    }
}
