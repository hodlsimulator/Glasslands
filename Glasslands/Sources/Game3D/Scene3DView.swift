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

        // Performance-first defaults (especially when the sky fills the screen)
        view.antialiasingMode = SCNAntialiasingMode.none
        view.isJitteringEnabled = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.isOpaque = true
        view.backgroundColor = UIColor.black

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = true
            metal.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            metal.pixelFormat = .bgra10_xr_srgb
            metal.maximumDrawableCount = 3
        }

        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        engine.attach(to: view, recipe: recipe)

        // Tone mapping/bloom so bright sprites (the sun) bloom on HDR.
        if let cam = view.pointOfView?.camera {
            cam.wantsHDR = true
            cam.wantsExposureAdaptation = true
            cam.exposureOffset = 0.0
            cam.averageGray = 0.18
            cam.whitePoint = 1.0
            cam.minimumExposure = -1.0
            cam.maximumExposure = 2.0
            cam.bloomIntensity = 1.25
            cam.bloomThreshold = 0.65
            cam.bloomBlurRadius = 12.0
        }

        let proxy = RendererProxy(engine: engine)
        context.coordinator.proxy = proxy
        view.delegate = proxy

        engine.setPaused(isPaused)

        DispatchQueue.main.async {
            onReady(engine)
        }

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var engine: FirstPersonEngine?
        var proxy: RendererProxy?
    }
}
