//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  UIViewRepresentable wrapper. Input comes from VirtualSticks.
//  Goal here: cool the game without touching clouds/shaders by pacing frames ourselves.
//  We stop SceneKit's own render loop and explicitly render at 40/30 fps using a display link.
//  Touch input stays responsive because the display link runs in .common mode at device max Hz.
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

        // IMPORTANT: disable SceneKit's internal render loop; we'll drive it.
        view.rendersContinuously = false
        view.isPlaying = false

        view.isOpaque = true
        view.backgroundColor = .black

        // Keep your original surface config (unchanged visuals).
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

        // Display link at device max Hz; we will "frame-skip" to achieve 40/30 fps.
        let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.onTick(_:)))
        context.coordinator.link = link
        link.add(to: .main, forMode: .common)

        // Decide our target fps once we have a window/screen.
        DispatchQueue.main.async {
            let maxHz = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            context.coordinator.targetFPS = (maxHz >= 120) ? 40 : 30
            context.coordinator.resetTiming()
        }

        // Initial safety default before window attaches.
        context.coordinator.targetFPS = 30
        context.coordinator.resetTiming()

        // Pause state
        engine.setPaused(isPaused)
        context.coordinator.paused = isPaused

        DispatchQueue.main.async { onReady(engine) }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        context.coordinator.paused = isPaused

        // If we just gained a window, recompute target fps once.
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

        // Sun diffusion throttle
        private var lastSunUpdate: CFTimeInterval = 0
        private let sunUpdateInterval: CFTimeInterval = 1.0 / 12.0

        // Pause flag mirrors engine pause
        var paused: Bool = false

        func resetTiming() {
            lastTS = 0
            accumulator = 0
            lastSunUpdate = 0
        }

        @objc func onTick(_ link: CADisplayLink) {
            guard !paused, let engine, let view else { return }

            let ts = link.timestamp
            if lastTS == 0 { lastTS = ts }  // prime
            let dt = max(0, ts - lastTS)
            lastTS = ts

            accumulator += dt
            if accumulator < interval {
                return // skip this vsync; keep input responsive, don't render
            }

            // Consume exactly one frame budget; carry remainder to keep cadence stable.
            accumulator -= interval

            // Drive game + clouds at our paced rate.
            engine.stepUpdateMain(at: ts)
            engine.tickVolumetricClouds(atRenderTime: ts)

            // Keep ground shade alive but cheap.
            if ts - lastSunUpdate >= sunUpdateInterval {
                engine.updateSunDiffusion()
                lastSunUpdate = ts
            }

            // Explicit render. SceneKit draws once because rendersContinuously=false.
            view.setNeedsDisplay()
        }
    }
}
