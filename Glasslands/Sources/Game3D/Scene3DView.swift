//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  UIViewRepresentable wrapper. No gestures here—input comes from VirtualSticks.
//

import SwiftUI
import SceneKit
import MetalKit

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    let isPaused: Bool
    let onScore: (Int) -> Void
    let onReady: (FirstPersonEngine) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.preferredRenderingAPI = .metal
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

        // Start with composited presentation (disables Direct-to-Display)
        view.isOpaque = false

        if let metal = view.layer as? CAMetalLayer {
            metal.wantsExtendedDynamicRangeContent = false
            metal.pixelFormat = .bgra8Unorm
            metal.maximumDrawableCount = 3
        }

        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine
        engine.attach(to: view, recipe: recipe)

        let proxy = RendererProxy(engine: engine)
        context.coordinator.proxy = proxy
        view.delegate = proxy

        engine.setPaused(isPaused)

        DispatchQueue.main.async { onReady(engine) }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var engine: FirstPersonEngine?
        var proxy: RendererProxy?
    }
}
