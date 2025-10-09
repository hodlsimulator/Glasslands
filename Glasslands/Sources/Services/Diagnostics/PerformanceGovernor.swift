//
//  PerformanceGovernor.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//

import Foundation
import SceneKit
import QuartzCore
import UIKit
@preconcurrency import ObjectiveC

@MainActor
final class PerformanceGovernor {
    static let shared = PerformanceGovernor()

    private weak var view: SCNView?
    private weak var engine: FirstPersonEngine?
    private var thermalObs: NSObjectProtocol?
    private var powerObs: NSObjectProtocol?

    private init() {}

    func attach(view: SCNView, engine: FirstPersonEngine) {
        self.view = view
        self.engine = engine

        thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPolicy() }
        }

        powerObs = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPolicy() }
        }

        applyPolicy()
    }

    func applyPolicy() {
        guard let v = view else { return }

        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let ts  = ProcessInfo.processInfo.thermalState
        let maxFPS = v.window?.windowScene?.screen.maximumFramesPerSecond ?? 60

        // Keep rendering continuous for responsiveness; cool via FPS cap only.
        let cap: Int
        if maxFPS >= 120 {
            cap = (ts == .serious || ts == .critical || lpm) ? 30 : 40
        } else {
            cap = 30
        }
        v.preferredFramesPerSecond = cap
        v.rendersContinuously = true

        // Do NOT switch cloud modes at runtime — keep pipeline stable.

        // Throttle world streaming a bit under pressure.
        engine?.chunker?.tasksPerFrame = (ts == .serious || ts == .critical || lpm) ? 1 : 2

        // Shadows: avoid heavy reallocation. Only trim distance and sample count.
        if let sun = engine?.sunLightNode?.light {
            switch ts {
            case .serious, .critical:
                sun.maximumShadowDistance = 320
                sun.shadowSampleCount = 1
            case .fair:
                sun.maximumShadowDistance = 420
                sun.shadowSampleCount = 2
            default:
                sun.maximumShadowDistance = 560
                sun.shadowSampleCount = 3
            }
        }

        // Bloom trims are cheap and help a little thermally.
        if let cam = v.pointOfView?.camera {
            switch ts {
            case .serious, .critical:
                cam.wantsHDR = false
                cam.bloomIntensity = 0
                cam.bloomBlurRadius = 0
            case .fair:
                cam.wantsHDR = false
                cam.bloomThreshold = 1.20
                cam.bloomIntensity = 0.60
                cam.bloomBlurRadius = 8
            default:
                cam.wantsHDR = false
                cam.bloomThreshold = 1.15
                cam.bloomIntensity = 0.90
                cam.bloomBlurRadius = 10
            }
        }
    }
}
