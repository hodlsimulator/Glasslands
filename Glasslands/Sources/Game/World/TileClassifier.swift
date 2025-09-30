//
//  TileClassifier.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
//  Classifies world tiles from noise fields into useful terrain types.
//

import UIKit

enum TileType: UInt8 {
    case deepWater, shallowWater, river, sand, grass, forest, rock, snow

    var isBlocked: Bool {
        switch self {
        case .deepWater, .rock:
            return true
        default:
            return false
        }
    }
}

final class TileClassifier {
    private let ctx: WorldContext
    init(context: WorldContext) { self.ctx = context }
    var context: WorldContext { ctx }

    /// Main classification using height, moisture, slope, and river mask.
    func tile(at tile: IVec2) -> TileType {
        let x = Double(tile.x)
        let y = Double(tile.y)
        let h = ctx.noise.sampleHeight(x, y)        // 0..ampH (≈0..1)
        let m = ctx.noise.sampleMoisture(x, y)      // 0..ampM (≈0..1)
        let s = ctx.noise.slope(x, y)               // slope magnitude
        let r = ctx.noise.riverMask(x, y)           // 0..1

        // Sea levels & bands tuned for nice variety across amplitudes.
        // Treat 'h' as a 0..1-ish normalised signal; thresholds chosen by look.
        let deep = 0.18
        let shallow = 0.28
        let beach = 0.34
        let lowland = 0.62
        let highland = 0.82

        // Rivers: only above deep water; strong mask means channel.
        if h >= shallow, r > 0.55 {
            return .river
        }

        switch h {
        case ..<deep:     return .deepWater
        case ..<shallow:  return .shallowWater
        case ..<beach:    return .sand
        case ..<lowland:  return (m > 0.55 && s < 0.12) ? .forest : .grass
        case ..<highland: return .rock
        default:          return .snow
        }
    }

    /// Debug/2D colours derived from the biome palette.
    func color(for t: TileType) -> UIColor {
        let pal = AppColours.uiColors(from: ctx.recipe.paletteHex)
        func pick(_ i: Int) -> UIColor { pal.indices.contains(i) ? pal[i] : .gray }

        switch t {
        case .deepWater:    return pick(1)                 // darker water
        case .shallowWater: return pick(0)                 // lighter water
        case .river:        return pick(0).withAlphaComponent(0.9)
        case .sand:         return pick(3)
        case .grass:        return pick(2)
        case .forest:       return pick(2).withAlphaComponent(0.85)
        case .rock:         return .darkGray
        case .snow:         return .white
        }
    }
}
