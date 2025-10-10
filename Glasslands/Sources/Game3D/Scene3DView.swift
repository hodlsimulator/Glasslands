//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  UIViewRepresentable wrapper. Uses a single SceneKit-driven render loop via RendererProxy.
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

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = true
            metal.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            metal.pixelFormat = .bgra10_xr_srgb
            metal.maximumDrawableCount = 3
        }

        // Engine
        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        context.coordinator.view = view

        engine.attach(to: view, recipe: recipe)

        // Camera HDR/exposure
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

        // Single render loop via SceneKit delegate.
        let proxy = RendererProxy(engine: engine)
        view.delegate = proxy
        context.coordinator.delegateProxy = proxy

        view.rendersContinuously = true
        view.isPlaying = !isPaused
        engine.setPaused(isPaused)

        // Pick an initial fps cap; refine once we have a window.
        view.preferredFramesPerSecond = 30
        DispatchQueue.main.async { [weak view] in
            guard let v = view else { return }
            v.preferredFramesPerSecond = desiredFPS(for: v)
        }

        DispatchQueue.main.async {
            onReady(engine)
        }

        // Observe thermal changes to gently drop to 30fps when hot.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.onThermalChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        uiView.isPlaying = !isPaused

        // Re-evaluate the desired cap on rotation / window changes.
        let newFPS = desiredFPS(for: uiView)
        if uiView.preferredFramesPerSecond != newFPS {
            uiView.preferredFramesPerSecond = newFPS
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        uiView.isPlaying = false
        uiView.delegate = nil
        coordinator.delegateProxy = nil
        coordinator.engine = nil
        coordinator.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    private func desiredFPS(for view: SCNView) -> Int {
        let screenHz = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let baseCap = (screenHz >= 120) ? 40 : 30
        let thermal = ProcessInfo.processInfo.thermalState
        return (thermal == .serious || thermal == .critical) ? 30 : baseCap
    }

    @MainActor
    final class Coordinator: NSObject {
        var engine: FirstPersonEngine?
        weak var view: SCNView?
        var delegateProxy: RendererProxy?

        @objc func onThermalChanged() {
            guard let v = view else { return }
            let newFPS = (v.window?.windowScene?.screen.maximumFramesPerSecond ?? 60) >= 120 ? 40 : 30
            let thermal = ProcessInfo.processInfo.thermalState
            v.preferredFramesPerSecond = (thermal == .serious || thermal == .critical) ? 30 : newFPS
        }
    }
}
