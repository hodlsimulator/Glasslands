//
//  SaveStore.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation

final class SaveStore {
    static let shared = SaveStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let seedCharm = "glasslands.seedCharm"
    }

    var lastSeedCharm: String? {
        get { defaults.string(forKey: Keys.seedCharm) }
        set { defaults.set(newValue, forKey: Keys.seedCharm) }
    }
}
