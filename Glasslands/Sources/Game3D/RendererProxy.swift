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

    // Coalesces multiple render-thread callbacks into a single MainActor task.
    // This avoids per-frame Task creation and prevents backlog-induced latency.
    private final class FramePump: @unchecked Sendable {
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

    // Stored as a Sendable closure so the nonisolated SceneKit callback doesn’t
    // directly touch main-isolated objects.
    private let tick: @Sendable (TimeInterval) -> Void

    init(engine: FirstPersonEngine) {
        let pump = FramePump(engine: engine)
        self.tick = { t in
            pump.push(t)
        }
        super.init()
    }

    // Non-isolated so SceneKit can call this from its render queue.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        tick(time)
    }
}
