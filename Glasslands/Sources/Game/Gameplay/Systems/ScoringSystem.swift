//
//  ScoringSystem.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation

final class ScoringSystem {
    private(set) var total: Int = 0
    func onBeaconCollected() -> Int {
        total += 1
        return total
    }
}
