//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  UIViewRepresentable wrapper. Input comes from VirtualSticks.
//

import SwiftUI
import SceneKit
import QuartzCore
import Metal
import UIKit

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    let isPaused: Bool
    let onScore: (Int) -> Void
    let onReady: (FirstPersonEngine) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .none
        view.isJitteringEnabled = false

        // Manual pacing: SceneKit draws only when asked.
        view.rendersContinuously = false
        view.isPlaying = false

        view.isOpaque = true
        view.backgroundColor = .black

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = true
            metal.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            metal.pixelFormat = .bgra10_xr_srgb
            metal.maximumDrawableCount = 3
        }

        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        context.coordinator.view = view
        engine.attach(to: view, recipe: recipe)

        if let cam = view.pointOfView?.camera {
            cam.wantsHDR = true
            cam.wantsExposureAdaptation = false
            cam.exposureOffset = -0.25
            cam.averageGray = 0.18
            cam.whitePoint = 1.0
            cam.minimumExposure = -3.0
            cam.maximumExposure = 3.0
            cam.bloomThreshold = 1.15
            cam.bloomIntensity = 1.25
            cam.bloomBlurRadius = 12.0
        }

        let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.onTick(_:)))
        context.coordinator.link = link
        link.add(to: .main, forMode: .common)

        // Decide target FPS once attached to a screen.
        DispatchQueue.main.async {
            let maxHz = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            context.coordinator.targetFPS = (maxHz >= 120) ? 40 : 30
            context.coordinator.resetTiming()
        }
        // Safety default before window exists.
        context.coordinator.targetFPS = 30
        context.coordinator.resetTiming()

        engine.setPaused(isPaused)
        context.coordinator.paused = isPaused

        DispatchQueue.main.async { onReady(engine) }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        context.coordinator.paused = isPaused

        if let screenHz = uiView.window?.windowScene?.screen.maximumFramesPerSecond {
            let desired = (screenHz >= 120) ? 40 : 30
            if context.coordinator.targetFPS != desired {
                context.coordinator.targetFPS = desired
                context.coordinator.resetTiming()
            }
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.link?.invalidate()
        coordinator.link = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var engine: FirstPersonEngine?
        weak var view: SCNView?
        var link: CADisplayLink?

        // Frame pacing
        var targetFPS: Int = 30
        private var lastTS: CFTimeInterval = 0
        private var accumulator: CFTimeInterval = 0
        private var interval: CFTimeInterval { 1.0 / CFTimeInterval(max(1, targetFPS)) }

        // Ground shade cadence
        private var lastSunUpdate: CFTimeInterval = 0
        private let sunUpdateInterval: CFTimeInterval = 1.0 / 12.0

        var paused: Bool = false

        func resetTiming() {
            lastTS = 0
            accumulator = 0
            lastSunUpdate = 0
        }

        @objc func onTick(_ link: CADisplayLink) {
            guard !paused, let engine, let view else { return }

            let ts = link.timestamp
            if lastTS == 0 { lastTS = ts }
            let dt = max(0, ts - lastTS)
            lastTS = ts

            // Auto-drop when hot (keep visuals, just pace slower).
            let screenHz = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            let baseCap = (screenHz >= 120) ? 40 : 30
            let thState = ProcessInfo.processInfo.thermalState
            let desired = (thState == .serious || thState == .critical) ? 30 : baseCap
            if desired != targetFPS {
                targetFPS = desired
                resetTiming()
            }

            accumulator += dt
            if accumulator < interval { return }
            accumulator -= interval

            engine.stepUpdateMain(at: ts)
            engine.tickVolumetricClouds(atRenderTime: ts)

            if ts - lastSunUpdate >= sunUpdateInterval {
                engine.updateSunDiffusion()
                lastSunUpdate = ts
            }

            view.setNeedsDisplay()
        }
    }
}
