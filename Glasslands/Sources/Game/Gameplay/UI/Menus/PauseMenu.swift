//
//  PauseMenu.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
// SwiftUI HUD overlays handle pause/resume; this file remains for future expansion.
//

import SwiftUI

struct PauseMenu: View {
    var onResume: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("Paused").font(.largeTitle.bold())
            Button("Resume", action: onResume).buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
