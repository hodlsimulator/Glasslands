//
//  ContentView.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI
import SpriteKit

final class GameViewModel: ObservableObject {
    @Published var seedCharm: String = SaveStore.shared.lastSeedCharm ?? "RAIN_FOX_PEAKS"
    @Published var score: Int = 0
    @Published var isPaused: Bool = false

    let biomeService = BiomeSynthesisService()
    let imageService = ImageCreatorService()

    func makeScene(size: CGSize) -> SKScene {
        let recipe = biomeService.recipe(for: seedCharm)
        SaveStore.shared.lastSeedCharm = seedCharm

        let scene = GameScene(size: size,
                              recipe: recipe,
                              onScore: { [weak self] newScore in
                                  DispatchQueue.main.async { self?.score = newScore }
                              })
        scene.scaleMode = .resizeFill
        scene.isPaused = isPaused
        return scene
    }
}

struct ContentView: View {
    @StateObject private var vm = GameViewModel()
    @State private var scene: SKScene?

    private func rebuildScene(for size: CGSize) {
        scene = vm.makeScene(size: size)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let scene {
                    SpriteView(scene: scene, debugOptions: [])
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                HUDOverlay(seedCharm: $vm.seedCharm,
                           score: vm.score,
                           isPaused: $vm.isPaused,
                           onApplySeed: {
                               rebuildScene(for: geo.size)
                           },
                           onSavePostcard: {
                               guard let gs = scene as? GameScene,
                                     let image = gs.captureSnapshot() else { return }
                               Task {
                                   do {
                                       let postcard = try await vm.imageService.generatePostcard(from: image,
                                                                                                  title: vm.seedCharm,
                                                                                                  palette: gs.paletteUIColors)
                                       try await PhotoSaver.saveImageToPhotos(postcard)
                                   } catch {
                                       print("Postcard save failed:", error)
                                   }
                               }
                           },
                           onShowLeaderboards: {
                               GameCenterHelper.shared.presentLeaderboards()
                           })
                    .padding(.top, 8)
            }
            .onAppear { rebuildScene(for: geo.size) }
            .onChange(of: vm.isPaused) { _, newValue in
                (scene as? GameScene)?.isPaused = newValue
            }
        }
    }
}
