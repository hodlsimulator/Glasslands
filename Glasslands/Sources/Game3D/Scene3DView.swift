//
//  Scene3DView.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
// UIViewRepresentable wrapper. No gestures here—input comes from VirtualSticks.
//

import SwiftUI
import SceneKit

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    var isPaused: Bool
    var onScore: (Int) -> Void
    var onReady: (FirstPersonEngine) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black

        let engine = FirstPersonEngine(onScore: onScore)
        engine.attach(to: view, recipe: recipe)
        engine.setPaused(isPaused)
        onReady(engine)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        (uiView.delegate as? FirstPersonEngine)?.setPaused(isPaused)
        (uiView.delegate as? FirstPersonEngine)?.apply(recipe: recipe) // no-op if unchanged
    }
}
