//
//  ContentView.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
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
    @State private var runHUD = FirstPersonEngine.RunHUDSnapshot(
        banked: 0,
        carrying: 0,
        secondsRemaining: 240,
        canBankNow: false,
        runEnded: false,
        chapterTitle: "Chapter I  First Light",
        objectiveText: "Collect beacons from nearby ridges.",
        bankPromptText: "Bank",
        bankRadiusMeters: 4.0,
        waystoneDebugText: "Waystone: missing",
        debugFpsDisplay: 60,
        debugFpsMin1s: 60,
        debugLowFpsThreshold: 55,
        debugLowFpsActive: false,
        debugActiveToggles: "none",
        debugCpuFrameMs: 0,
        debugCpuMoveMs: 0,
        debugCpuChunkMs: 0,
        debugCpuCloudMs: 0,
        debugCpuSkyMs: 0,
        debugCpuSubmitMs: 0,
        debugPerfHint: "CPU/GPU stable",
        debugCloudLodInfo: "Cloud LOD t0 q1.00 hz60 far1.00 dither=off"
    )
    private let hudTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private func applySeed() {
        engine?.apply(recipe: vm.recipe())
    }

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
                banked: runHUD.banked,
                carrying: runHUD.carrying,
                secondsRemaining: runHUD.secondsRemaining,
                canBankNow: runHUD.canBankNow,
                runEnded: runHUD.runEnded,
                chapterTitle: runHUD.chapterTitle,
                objectiveText: runHUD.objectiveText,
                bankPromptText: runHUD.bankPromptText,
                waystoneDebugText: runHUD.waystoneDebugText,
                debugFpsDisplay: runHUD.debugFpsDisplay,
                debugFpsMin1s: runHUD.debugFpsMin1s,
                debugLowFpsThreshold: runHUD.debugLowFpsThreshold,
                debugLowFpsActive: runHUD.debugLowFpsActive,
                debugActiveToggles: runHUD.debugActiveToggles,
                debugCpuFrameMs: runHUD.debugCpuFrameMs,
                debugCpuMoveMs: runHUD.debugCpuMoveMs,
                debugCpuChunkMs: runHUD.debugCpuChunkMs,
                debugCpuCloudMs: runHUD.debugCpuCloudMs,
                debugCpuSkyMs: runHUD.debugCpuSkyMs,
                debugCpuSubmitMs: runHUD.debugCpuSubmitMs,
                debugPerfHint: runHUD.debugPerfHint,
                debugCloudLodInfo: runHUD.debugCloudLodInfo,
                isPaused: $vm.isPaused,
                onApplySeed: {
                    applySeed()
                },
                onBank: {
                    engine?.bankNow()
                    if let engine { runHUD = engine.runHUDSnapshot() }
                },
                onNewRun: {
                    engine?.apply(recipe: vm.recipe(), force: true)
                    if let engine { runHUD = engine.runHUDSnapshot() }
                },
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
                            engine.setMoveInput(vec) // x = strafe, y = forward
                        }
                        Spacer(minLength: 24)
                        // Swipe-to-look (no inertia)
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
        .onReceive(hudTimer) { _ in
            guard let engine else { return }
            runHUD = engine.runHUDSnapshot()
            vm.score = runHUD.banked
        }
    }
}
