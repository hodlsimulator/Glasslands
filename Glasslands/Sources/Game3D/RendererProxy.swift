//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// Receives SceneKit callbacks on the render thread, then schedules the real
/// update on the MainActor. Sun diffusion (cloud shadow/gobo) is *disabled*
/// keeps the render loop responsive while we debug the stall.
final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    private weak var engineRef: FirstPersonEngine?

    init(engine: FirstPersonEngine) {
        self.engineRef = engine
        super.init()
    }

    // SceneKit may call this from its render queue; hop to MainActor for engine work.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        Task { @MainActor in
            guard let engine = self.engineRef else { return }

            // Main engine tick
            engine.stepUpdateMain(at: time)

            // Drive cloud uniforms/advection (cheap)
            engine.tickVolumetricClouds(atRenderTime: time)

            // NOTE: sun diffusion (cloud shadow/gobo) intentionally disabled to stop hangs
            // engine.updateSunDiffusion()
        }
    }
}
