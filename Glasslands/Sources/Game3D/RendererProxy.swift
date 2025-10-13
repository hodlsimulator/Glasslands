//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Receives SceneKit callbacks on the render thread, then schedules the real
//  update on the MainActor without touching main-isolated state here.
//

import Foundation
import SceneKit

final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    // We avoid storing/reading a @MainActor object here.
    // Instead we store a @Sendable tick closure built on the main thread that hops to MainActor inside.
    private let tick: @Sendable (TimeInterval) -> Void

    init(engine: FirstPersonEngine) {
        // Build the closure on main, capturing the engine weakly and hopping to MainActor inside.
        self.tick = { [weak engine] t in
            Task { @MainActor in
                engine?.stepUpdateMain(at: t)
                // Keep volumetrics driven by a stable render-time clock.
                engine?.tickVolumetricClouds(atRenderTime: t)
                // Drive sun diffusion (light + shadows + halo) every frame.
                engine?.updateSunDiffusion()
            }
        }
        super.init()
    }

    // Non-isolated so SceneKit can call this from its render queue without assertions.
    // No main-isolated state is touched directly here.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        tick(time)
    }
}
