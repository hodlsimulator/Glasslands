//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// SceneKit render delegate: coalesces per-frame work and throttles cloud updates.
/// Avoids piling up MainActor Tasks when the camera turns quickly.
final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    private weak var engineRef: FirstPersonEngine?

    @MainActor private var lastCloudTick: TimeInterval = 0
    @MainActor private let minCloudDelta: TimeInterval = 1.0 / 24.0  // 24 Hz cloud uniforms/advection

    init(engine: FirstPersonEngine) {
        self.engineRef = engine
        super.init()
    }

    // Called on SceneKit's render queue.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        Task { @MainActor in
            guard let engine = self.engineRef else { return }

            // Game/scene tick (keep this light; heavy work lives off the main thread).
            engine.stepUpdateMain(at: time)

            // Clouds: update at most 24 Hz; use latest time only.
            if time - lastCloudTick >= minCloudDelta {
                lastCloudTick = time
                engine.tickVolumetricClouds(atRenderTime: time)
            }
        }
    }
}
