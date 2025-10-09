//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// SceneKit render delegate: one main tick per frame.
/// Ground shade is updated inside the engine (throttled there).
final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    private weak var engineRef: FirstPersonEngine?

    init(engine: FirstPersonEngine) {
        self.engineRef = engine
        super.init()
    }

    // SceneKit render queue → hop to MainActor for scene work.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        Task { @MainActor in
            guard let engine = self.engineRef else { return }
            engine.stepUpdateMain(at: time)
            engine.updateSunDiffusion()   // <- was updateSunDiffusionThrottled()
        }
    }
}
