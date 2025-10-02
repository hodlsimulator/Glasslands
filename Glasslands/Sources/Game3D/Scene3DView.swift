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

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    var isPaused: Bool
    var onScore: (Int) -> Void
    var onReady: (FirstPersonEngine) -> Void

    final class Coordinator {
        var engine: FirstPersonEngine?
        var proxy: RendererProxy?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .none          // A/B: MSAA off
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

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

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let engine = context.coordinator.engine else { return }
        engine.setPaused(isPaused)
        engine.apply(recipe: recipe) // no-op if unchanged
    }
}
