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

    // Keep a strong reference to the engine so it isn't released.
    final class Coordinator {
        var engine: FirstPersonEngine?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black

        // Ensure SwiftUI overlay (virtual sticks) always receives touches.
        view.isUserInteractionEnabled = false

        let engine = FirstPersonEngine(onScore: onScore)
        context.coordinator.engine = engine

        engine.attach(to: view, recipe: recipe)
        engine.setPaused(isPaused)

        // Surface the engine to SwiftUI so ContentView can wire the sticks.
        DispatchQueue.main.async {
            onReady(engine)
        }

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let engine = context.coordinator.engine else { return }
        engine.setPaused(isPaused)
        engine.apply(recipe: recipe) // no-op if unchanged
    }
}
