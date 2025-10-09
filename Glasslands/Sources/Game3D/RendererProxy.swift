//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// SceneKit render delegate that coalesces frame updates onto the MainActor.
/// Prevents an unbounded queue of per-frame Tasks on the main thread.
final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    private weak var engineRef: FirstPersonEngine?

    // MainActor state used to coalesce/tick exactly once per frame.
    @MainActor private var hasWork: Bool = false
    @MainActor private var latestTime: TimeInterval = 0

    init(engine: FirstPersonEngine) {
        self.engineRef = engine
        super.init()
    }

    // Called on SceneKit's render queue. Push a single coalesced tick to Main.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        Task { @MainActor in
            latestTime = time
            if hasWork { return }        // already scheduled → coalesce
            hasWork = true
            while true {
                let t = latestTime
                guard let engine = self.engineRef else { break }

                // Main engine tick (UI/scene mutations happen here)
                engine.stepUpdateMain(at: t)

                // Cloud uniforms/advection etc.
                engine.tickVolumetricClouds(atRenderTime: t)

                // If no newer request arrived during the tick, we’re done.
                if t == latestTime { break }
            }
            hasWork = false
        }
    }
}
