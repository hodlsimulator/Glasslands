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

// File-scope so it does not inherit any global-actor isolation inferred for RendererProxy.
private final class RenderFramePump: @unchecked Sendable {

    private weak var engine: FirstPersonEngine?

    private let lock = NSLock()
    private var scheduled = false
    private var pendingTime: TimeInterval?

    init(engine: FirstPersonEngine) {
        self.engine = engine
    }

    func push(_ t: TimeInterval) {
        var shouldSchedule = false

        lock.lock()
        pendingTime = t
        if !scheduled {
            scheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        while true {
            lock.lock()
            let t = pendingTime
            pendingTime = nil
            if t == nil {
                scheduled = false
            }
            lock.unlock()

            guard let t else { return }
            guard let engine else { return }

            engine.stepUpdateMain(at: t)
            engine.tickVolumetricClouds(atRenderTime: t)
            engine.updateSunDiffusion()
        }
    }
}

final class RendererProxy: NSObject, SCNSceneRendererDelegate {

    // Nonisolated so the render-thread callback can access it even if this type is inferred @MainActor.
    nonisolated private let tick: @Sendable (TimeInterval) -> Void

    init(engine: FirstPersonEngine) {
        let pump = RenderFramePump(engine: engine)
        self.tick = { t in
            pump.push(t)
        }
        super.init()
    }

    // SceneKit may call this from a render thread.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        tick(time)
    }
}
