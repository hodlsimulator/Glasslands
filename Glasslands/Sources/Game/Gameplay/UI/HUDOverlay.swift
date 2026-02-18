//
//  HUDOverlay.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI
import Foundation

struct HUDOverlay: View {
    @Binding var seedCharm: String
    let banked: Int
    let carrying: Int
    let secondsRemaining: Int
    let canBankNow: Bool
    let runEnded: Bool
    let chapterTitle: String
    let objectiveText: String
    let bankPromptText: String
    let waystoneDebugText: String
    let debugFpsDisplay: Int
    let debugFpsMin1s: Int
    let debugLowFpsThreshold: Int
    let debugLowFpsActive: Bool
    let debugActiveToggles: String
    let debugCpuFrameMs: Double
    let debugCpuMoveMs: Double
    let debugCpuChunkMs: Double
    let debugCpuCloudMs: Double
    let debugCpuSkyMs: Double
    let debugCpuSubmitMs: Double
    let debugPerfHint: String
    let debugCloudLodInfo: String
    @Binding var isPaused: Bool

    let onApplySeed: () -> Void
    let onBank: () -> Void
    let onNewRun: () -> Void
    let onSavePostcard: () -> Void
    let onShowLeaderboards: () -> Void

    private var duskText: String {
        let mm = max(0, secondsRemaining) / 60
        let ss = max(0, secondsRemaining) % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    var body: some View {
        VStack(spacing: 8) {

            // Top bar: compact while playing
            HStack(alignment: .center, spacing: 8) {
                Text("Banked \(banked)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                Text("Carrying \(carrying)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                Text("Dusk \(duskText)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                Spacer(minLength: 12)

                if canBankNow {
                    Button(bankPromptText) { onBank() }
                        .buttonStyle(.borderedProminent)
                }
                if runEnded {
                    Button("New Run") { onNewRun() }
                        .buttonStyle(.borderedProminent)
                }

                Button(isPaused ? "Resume" : "Pause") { isPaused.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)

            #if DEBUG
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(debugLowFpsActive ? Color.red : Color.green)
                        .frame(width: 9, height: 9)
                    Text("FPS \(debugFpsDisplay) (min \(debugFpsMin1s), <\(debugLowFpsThreshold))")
                        .font(.caption.monospacedDigit())
                }
                Text(String(
                    format: "CPU %.1fms | move %.1f chunk %.1f cloud %.1f sky %.1f submit %.1f",
                    debugCpuFrameMs, debugCpuMoveMs, debugCpuChunkMs, debugCpuCloudMs, debugCpuSkyMs, debugCpuSubmitMs
                ))
                    .font(.caption.monospacedDigit())
                Text("Perf: \(debugPerfHint)")
                    .font(.caption.monospaced())
                Text(debugCloudLodInfo)
                    .font(.caption2.monospaced())
                Text("Toggles: \(debugActiveToggles)")
                    .font(.caption2.monospaced())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            #endif

            Text(chapterTitle)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())

            Text(objectiveText)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())

            Text(waystoneDebugText)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            // Secondary controls only when paused (keeps the play area clear)
            if isPaused {
                HStack(spacing: 8) {
                    TextField("Seed charm (e.g. RAIN_FOX_PEAKS)", text: $seedCharm)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .font(.callout.monospaced())
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    Button("Apply") { onApplySeed() }
                        .buttonStyle(.bordered)
                    Button("Postcard") { onSavePostcard() }
                        .buttonStyle(.bordered)
                    Button("Leaderboards") { onShowLeaderboards() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: isPaused)
        .padding(.top, 8)
    }
}
