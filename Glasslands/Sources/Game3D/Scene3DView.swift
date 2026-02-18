//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  UIViewRepresentable wrapper. Uses a single SceneKit-driven render loop via RendererProxy.
//  Engine is created here and returned via onReady.
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

        // Visual setup
        view.antialiasingMode = .none
        view.isJitteringEnabled = false
        view.isOpaque = true
        view.backgroundColor = .black
        #if DEBUG
        view.showsStatistics = true
        #endif

        // Main surface: keep EDR OFF and use 8-bit sRGB (cheaper & stabler for big translucent passes)
        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = false
            metal.colorspace = CGColorSpaceCreateDeviceRGB()
            metal.pixelFormat = .bgra8Unorm_srgb
            metal.maximumDrawableCount = 3
        }

        // Engine
        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        context.coordinator.view = view

        engine.attach(to: view, recipe: recipe)
        engine.prewarmSunDiffusion()

        // Camera HDR / exposure
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

        // Single render loop via SceneKit delegate (proxy hops to MainActor)
        let proxy = RendererProxy(engine: engine)
        view.delegate = proxy
        context.coordinator.delegateProxy = proxy

        view.rendersContinuously = true
        view.isPlaying = !isPaused

        // Hard-cap at 60 FPS for stability on iOS
        view.preferredFramesPerSecond = 60

        // Tell host that the engine is ready
        DispatchQueue.main.async { onReady(engine) }

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        uiView.isPlaying = !isPaused
        // Reassert 60 FPS if anything external changed it
        if uiView.preferredFramesPerSecond != 60 {
            uiView.preferredFramesPerSecond = 60
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        uiView.isPlaying = false
        uiView.delegate = nil
        coordinator.delegateProxy = nil
        coordinator.engine = nil
        coordinator.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var engine: FirstPersonEngine?
        weak var view: SCNView?
        var delegateProxy: RendererProxy?
    }
}
