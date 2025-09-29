//
//  Colours.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI
import UIKit

enum AppColours {
    // Default palette; replaced per-biome at runtime
    static let paletteHex = ["#8BC7DA","#36667C","#E0F2F6","#F3E2C0","#704B2C"]

    static func uiColors(from hexes: [String]) -> [UIColor] {
        hexes.compactMap { UIColor(hex: $0) }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
