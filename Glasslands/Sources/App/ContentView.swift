//
//  ContentView.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
//  Glasslands/Sources/App/ContentView.swift
//  Slim SwiftUI host that wires HUD + 3D view + virtual sticks.
//

import SwiftUI
import Combine
import GameKit
import UIKit

final class GameViewModel: ObservableObject {
    @Published var seedCharm: String = SaveStore.shared.lastSeedCharm ?? "RAIN_FOX_PEAKS"
    @Published var score: Int = 0
    @Published var isPaused: Bool = false

    let biomeService = BiomeSynthesisService()
    let imageService = ImageCreatorService()

    func recipe() -> BiomeRecipe {
        let r = biomeService.recipe(for: seedCharm)
        SaveStore.shared.lastSeedCharm = seedCharm
        return r
    }
}

struct ContentView: View {
    @StateObject private var vm = GameViewModel()
    @State private var engine: FirstPersonEngine?
    @State private var lastSnapshot: UIImage?

    private func applySeed() { engine?.apply(recipe: vm.recipe()) }

    var body: some View {
        ZStack {
            // 3D view
            Scene3DView(
                recipe: vm.recipe(),
                isPaused: vm.isPaused,
                onScore: { vm.score = $0 },
                onReady: { engine = $0 }
            )
            .ignoresSafeArea()

            // HUD
            HUDOverlay(
                seedCharm: $vm.seedCharm,
                score: vm.score,
                isPaused: $vm.isPaused,
                onApplySeed: { applySeed() },
                onSavePostcard: {
                    guard let img = engine?.snapshot() else { return }
                    Task {
                        do {
                            let palette = AppColours.uiColors(from: vm.recipe().paletteHex)
                            let postcard = try await vm.imageService.generatePostcard(
                                from: img,
                                title: vm.seedCharm,
                                palette: palette
                            )
                            try await PhotoSaver.saveImageToPhotos(postcard)
                            lastSnapshot = postcard
                        } catch {
                            print("Postcard save failed:", error.localizedDescription)
                        }
                    }
                },
                onShowLeaderboards: {
                    if GKLocalPlayer.local.isAuthenticated {
                        GameCenterHelper.shared.presentLeaderboards()
                    } else {
                        GKLocalPlayer.local.authenticateHandler = { vc, err in
                            if let err { print("Game Center:", err.localizedDescription) }
                        }
                    }
                }
            )
            .padding(.top, 8)

            // Virtual sticks (bottom left/right)
            if let engine {
                VStack {
                    Spacer()
                    HStack {
                        MoveStickView { vec in
                            engine.setMoveInput(vec)   // x = strafe, y = forward
                        }
                        Spacer(minLength: 24)
                        // NEW: swipe-to-look (no inertia)
                        LookPadView { delta in
                            engine.applyLookDelta(points: delta)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 26)
                }
                .allowsHitTesting(true)
            }
        }
    }
}
