//
//  FirstPersonEngine+Config.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import Foundation
import simd

extension FirstPersonEngine {
    struct Config: Equatable {
        // World tiling and scale
        var tilesX: Int = 32
        var tilesZ: Int = 32
        var tileSize: Float = 1.0
        var heightScale: Float = 2.8

        // Streaming / visibility
        var preloadRadius: Int = 2
        var tasksPerFrame: Int = 2

        // Player & camera
        var eyeHeight: Float = 1.62
        var moveSpeed: Float = 3.6
        var playerRadius: Float = 0.25
        var lookSensitivityRadPerPoint: Float = 0.0024
        var maxPitchRadians: Float = .pi * 0.47 // ~85°

        // Sky & sun
        var skyCoverage: Float = 0.34
        var skyEdgeSoftness: Float = 0.20
        var skyTextureWidth: Int = 1280
        var skyTextureHeight: Int = 640
        var sunAzimuthDeg: Float = 35
        var sunElevationDeg: Float = 63
    }
}
