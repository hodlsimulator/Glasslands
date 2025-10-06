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

        if let cam = view.pointOfView?.camera {
            cam.wantsHDR = true
            cam.wantsExposureAdaptation = false
            cam.exposureOffset = -0.25    // matches resetWorld()
            cam.averageGray = 0.18
            cam.whitePoint = 1.0
            cam.minimumExposure = -3.0
            cam.maximumExposure = 3.0
            cam.bloomThreshold = 1.15
            cam.bloomIntensity = 1.25
            cam.bloomBlurRadius = 12.0
        }

        let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.onTick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            link.preferredFramesPerSecond = 60
        }
        context.coordinator.link = link
        link.add(to: .main, forMode: .default)

        engine.setPaused(isPaused)
        DispatchQueue.main.async { onReady(engine) }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        context.coordinator.link?.isPaused = isPaused
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.link?.invalidate()
        coordinator.link = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var engine: FirstPersonEngine?
        var link: CADisplayLink?

        // No deinit body; cleanup happens in dismantleUIView

        @objc func onTick(_ link: CADisplayLink) {
            let t = link.timestamp
            engine?.stepUpdateMain(at: t)
            engine?.tickVolumetricClouds(atRenderTime: t)
        }
    }
}
