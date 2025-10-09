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

        // Keep continuous rendering; cool via FPS cap only.
        let cap: Int
        if maxFPS >= 120 {
            cap = (ts == .serious || ts == .critical || lpm) ? 30 : 40
        } else {
            cap = 30
        }
        v.preferredFramesPerSecond = cap
        v.rendersContinuously = true

        // Gentle, allocation-free shadow trims.
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

        // Bloom trims are cheap.
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

        // Streaming budget per frame.
        engine?.chunker?.tasksPerFrame = (ts == .serious || ts == .critical || lpm) ? 1 : 2

        // True volumetric clouds: lower raymarch cost via uniforms (no pipeline switches).
        let U = VolCloudUniformsStore.shared.snapshot()

        let stepMul: Float
        let quality: Float
        switch (ts, lpm) {
        case (.serious, _), (.critical, _):
            stepMul = 0.62; quality = 0.60
        case (.fair, true):
            stepMul = 0.66; quality = 0.68
        case (.fair, false):
            stepMul = 0.70; quality = 0.75
        default:
            stepMul = 0.75; quality = 0.85
        }

        VolCloudUniformsStore.shared.configure(
            baseY: U.params0.w,
            topY: U.params1.x,
            coverage: U.params1.y,
            densityMul: U.params1.z,
            stepMul: stepMul,
            horizonLift: U.params2.z,
            detailMul: U.params2.w,
            puffScale: U.params3.w,
            puffStrength: U.params4.x,
            macroScale: U.params4.z,
            macroThreshold: U.params4.w
        )
        VolCloudUniformsStore.shared.setQuality(quality)
    }
}
