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
                    // Authenticate Game Center on launch.
                    await gcHelper.authenticate()
                }
        }
    }
}
