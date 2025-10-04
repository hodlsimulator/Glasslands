//
//  FirstPersonMover.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import Foundation
import simd

struct FirstPersonMover {
    var speed: Float
    var radius: Float

    init(speed: Float, radius: Float) {
        self.speed = speed
        self.radius = max(0.01, radius)
    }

    mutating func step(
        from pos: SIMD3<Float>,
        yaw: Float,
        moveAxis: SIMD2<Float>,
        dt: Float,
        groundHeight: (Float, Float) -> Float,
        obstacles: [Obstacle]
    ) -> SIMD3<Float> {
        var p = pos

        // SceneKit camera faces -Z at yaw=0 → forward is -Z
        let forward = SIMD2<Float>(-sinf(yaw), -cosf(yaw))
        let right   = SIMD2<Float>( forward.y, -forward.x )

        var wish = right * moveAxis.x + forward * moveAxis.y
        let len = max(1e-4, simd_length(wish))
        wish /= len

        let stepLen = speed * max(0, dt)
        p.x += wish.x * stepLen
        p.z += wish.y * stepLen

        p = resolveCollisionsXZ(p, playerR: radius, obstacles: obstacles, iterations: 3)

        let gy = groundHeight(p.x, p.z)
        p.y = gy
        return p
    }

    private func resolveCollisionsXZ(
        _ p0: SIMD3<Float>,
        playerR: Float,
        obstacles: [Obstacle],
        iterations: Int
    ) -> SIMD3<Float> {
        var p = p0
        for _ in 0..<iterations {
            for obs in obstacles {
                let dx = p.x - obs.centreXZ.x
                let dz = p.z - obs.centreXZ.y
                let d2 = dx*dx + dz*dz
                let rr = (playerR + obs.radius)
                if d2 < rr*rr {
                    let d = max(1e-4, sqrt(d2))
                    let nx = dx / d, nz = dz / d
                    let push = rr - d
                    p.x += nx * push
                    p.z += nz * push
                }
            }
        }
        return p
    }
}
