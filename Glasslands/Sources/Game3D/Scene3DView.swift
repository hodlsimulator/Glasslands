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
        view.isOpaque = true
        view.backgroundColor = .black

        // Build engine + scene
        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        engine.attach(to: view, recipe: recipe)

        // Keep render loop alive; cool via FPS cap. Do not touch CAMetalLayer here.
        view.isPlaying = !isPaused
        view.rendersContinuously = true
        let mfps = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        view.preferredFramesPerSecond = (mfps >= 120) ? 40 : 30

        // Camera trims (PerformanceGovernor may adjust bloom later)
        if let cam = view.pointOfView?.camera {
            cam.wantsHDR = false
            cam.wantsExposureAdaptation = false
            cam.exposureOffset = -0.25
            cam.averageGray = 0.18
            cam.whitePoint = 1.0
            cam.minimumExposure = -3.0
            cam.maximumExposure = 3.0
            cam.bloomThreshold = 1.15
            cam.bloomIntensity = 0.90
            cam.bloomBlurRadius = 10.0
        }

        // Drive updates via SceneKit render loop
        let proxy = RendererProxy(engine: engine)
        view.delegate = proxy
        context.coordinator.proxy = proxy

        // Thermal/power governance
        PerformanceGovernor.shared.attach(view: view, engine: engine)

        DispatchQueue.main.async {
            PerformanceGovernor.shared.applyPolicy()
            onReady(engine)
        }

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.isPlaying = !isPaused
        PerformanceGovernor.shared.applyPolicy()
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.proxy = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var engine: FirstPersonEngine?
        var proxy: RendererProxy?
    }
}
