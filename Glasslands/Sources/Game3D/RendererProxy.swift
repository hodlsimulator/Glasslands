//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// Receives SceneKit callbacks on the render thread, then schedules the real
/// update on the MainActor without touching main-isolated state here.
final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    // We avoid storing/reading a @MainActor object here.
    // Instead we store a @Sendable tick closure built on the main thread that hops to MainActor.
    private let tick: @Sendable (TimeInterval) -> Void

    init(engine: FirstPersonEngine) {
        // Build the closure on main, capturing the engine weakly and hopping to MainActor inside.
        self.tick = { [weak engine] t in
            Task { @MainActor in
                engine?.stepUpdateMain(at: t)
                // Keep volumetrics driven by a stable render-time clock.
                engine?.tickVolumetricClouds(atRenderTime: t)
                // NEW: drive sun diffusion (light + shadows + halo) from cloud occlusion every frame.
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
