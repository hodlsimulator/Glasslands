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
import QuartzCore

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    let isPaused: Bool
    let onScore: (Int) -> Void
    let onReady: (FirstPersonEngine) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true

        // Force CA compositing: any non-zero corner radius + clipping disables Direct-to-Display.
        view.isOpaque = false
        view.backgroundColor = UIColor(white: 0, alpha: 0.001)
        view.layer.cornerRadius = 0.5
        view.layer.masksToBounds = true

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = false
            metal.wantsExtendedDynamicRangeContent = false
            metal.pixelFormat = .bgra8Unorm
            metal.maximumDrawableCount = 3
            metal.presentsWithTransaction = true
        }

        // Transparent overlay keeps the compositing path bullet-proof.
        let overlay = UIView()
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.001)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

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
