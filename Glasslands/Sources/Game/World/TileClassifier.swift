//
//  TileClassifier.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import UIKit

enum TileType: UInt8 {
    case deepWater, shallowWater, sand, grass, forest, rock, snow

    var isBlocked: Bool {
        switch self { case .deepWater, .rock: return true; default: return false }
    }
}

final class TileClassifier {
    private let ctx: WorldContext
    init(context: WorldContext) { self.ctx = context }

    // Expose context safely for systems (collision, streaming)
    var context: WorldContext { ctx }

    func tile(at tile: IVec2) -> TileType {
        let x = Double(tile.x)
        let y = Double(tile.y)
        let h = ctx.noise.sampleHeight(x, y)
        let m = ctx.noise.sampleMoisture(x, y)

        // Thresholds adapt to biome amplitude
        switch h {
        case ..<0.18: return .deepWater
        case ..<0.28: return .shallowWater
        case ..<0.34: return .sand
        case ..<0.62: return m > 0.55 ? .forest : .grass
        case ..<0.82: return .rock
        default:      return .snow
        }
    }

    func color(for t: TileType) -> UIColor {
        let pal = AppColours.uiColors(from: ctx.recipe.paletteHex)
        func pick(_ i: Int) -> UIColor { pal.indices.contains(i) ? pal[i] : .gray }
        switch t {
        case .deepWater:   return pick(1)
        case .shallowWater:return pick(0)
        case .sand:        return pick(3)
        case .grass:       return pick(2)
        case .forest:      return pick(4)
        case .rock:        return .darkGray
        case .snow:        return .white
        }
    }
}
