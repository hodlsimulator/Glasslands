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

    // Store a @Sendable tick closure; it hops to the main thread safely.
    private let tick: @Sendable (TimeInterval) -> Void

    init(engine: FirstPersonEngine) {
        self.tick = { [weak engine] t in
            DispatchQueue.main.async {
                engine?.stepUpdateMain(at: t)
                engine?.tickVolumetricClouds(atRenderTime: t)
                engine?.updateSunDiffusion()
            }
        }
        super.init()
    }

    // SceneKit calls this off the main thread; do not touch main-isolated state here.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        tick(time)
    }
}
