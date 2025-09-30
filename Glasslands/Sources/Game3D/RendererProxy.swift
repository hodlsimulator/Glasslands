//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
import SceneKit

/// Lightweight delegate that receives SceneKit callbacks on the render thread,
/// then schedules the real update on the MainActor.
final class RendererProxy: NSObject {
    weak var engine: FirstPersonEngine?

    init(engine: FirstPersonEngine) {
        self.engine = engine
        super.init()
    }
}

// Treat the delegate conformance as pre-concurrency so it doesn't inherit MainActor isolation.
extension RendererProxy: @preconcurrency SCNSceneRendererDelegate {
    // This is called by SceneKit on its render thread.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Bounce to the MainActor before touching engine/SceneKit state.
        Task { @MainActor [weak engine] in
            engine?.stepUpdateMain(at: time)
        }
    }
}
