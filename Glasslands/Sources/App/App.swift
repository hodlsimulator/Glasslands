//
//  App.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI
import GameKit

@main
struct GlasslandsApp: App {
    @StateObject private var gcHelper = GameCenterHelper.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Delay Game Center auth to avoid the launch hitch.
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                    await gcHelper.authenticate()
                }
        }
    }
}
