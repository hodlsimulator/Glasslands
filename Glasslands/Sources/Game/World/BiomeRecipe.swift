//
//  BiomeRecipe.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation

struct NoiseParams: Codable, Equatable {
    var base: String        // "perlin" | "ridged" | "billow"
    var octaves: Int
    var amplitude: Double   // overall amp (used for classifier thresholds)
    var scale: Double       // world scale (bigger → smoother)
}

struct SetpieceDef: Codable, Equatable {
    var name: String
    var rarity: Double      // 0..1 probability per 32×32 tiles
}

struct MusicMood: Codable, Equatable {
    var mode: String
    var tempo: Int
}

struct BiomeRecipe: Codable, Equatable {
    var height: NoiseParams
    var moisture: NoiseParams
    var paletteHex: [String]
    var faunaTags: [String]
    var setpieces: [SetpieceDef]
    var weatherBias: String
    var music: MusicMood
    var seed64: UInt64
}
