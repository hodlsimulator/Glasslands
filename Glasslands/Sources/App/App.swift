//
//  App.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI

@main
struct GlasslandsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
            // Game Center disabled during development to avoid launch stalls.
            // Re-enable once configured in App Store Connect.
        }
    }
}
