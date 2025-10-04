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

    // Stateless step; caller supplies ground height sampler and obstacles list.
    mutating func step(
        from pos: SIMD3<Float>,
        yaw: Float,
        moveAxis: SIMD2<Float>,
        dt: Float,
        groundHeight: (Float, Float) -> Float,
        obstacles: [Obstacle]
    ) -> SIMD3<Float> {
        var p = pos

        // Local move → world XZ
        let forward = SIMD2<Float>(sin(yaw), cos(yaw))
        let right   = SIMD2<Float>( forward.y, -forward.x )
        var wish    = right * moveAxis.x + forward * moveAxis.y
        let len     = max(1e-4, simd_length(wish))
        wish       /= len

        // Integrate horizontal move
        let stepLen = speed * max(0, dt)
        p.x += wish.x * stepLen
        p.z += wish.y * stepLen

        // Resolve simple disc-vs-disc collisions in XZ
        p = resolveCollisionsXZ(p, playerR: radius, obstacles: obstacles, iterations: 3)

        // Clamp to terrain height + eye handled by caller outside (kept here as y passthrough)
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
        for _ in 0..<max(1, iterations) {
            var pushed = false
            for o in obstacles {
                let dx = p.x - o.centreXZ.x
                let dz = p.z - o.centreXZ.y
                let d2 = dx*dx + dz*dz
                let r  = playerR + o.radius
                if d2 < r*r {
                    let d = max(1e-4, sqrt(d2))
                    let nx = dx / d
                    let nz = dz / d
                    let push = r - d
                    p.x += nx * push
                    p.z += nz * push
                    pushed = true
                }
            }
            if !pushed { break }
        }
        return p
    }
}
