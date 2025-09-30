//
//  RendererProxy.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
@preconcurrency import SceneKit   // avoid MainActor requirements on the delegate

final class RendererProxy: NSObject, SCNSceneRendererDelegate {
    weak var engine: FirstPersonEngine?

    init(engine: FirstPersonEngine) {
        self.engine = engine
        super.init()
    }

    // Called by SceneKit on its render thread.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Hop the frame update to the MainActor to satisfy UIKit/SceneKit isolation.
        Task { @MainActor in
            self.engine?.stepUpdateMain(at: time)
        }
    }
}
