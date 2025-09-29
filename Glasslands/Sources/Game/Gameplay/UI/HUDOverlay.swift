//
//  HUDOverlay.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI

struct HUDOverlay: View {
    @Binding var seedCharm: String
    let score: Int
    @Binding var isPaused: Bool

    let onApplySeed: () -> Void
    let onSavePostcard: () -> Void
    let onShowLeaderboards: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Score \(score)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                Button(isPaused ? "Resume" : "Pause") { isPaused.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)

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

            Spacer()
        }
    }
}
