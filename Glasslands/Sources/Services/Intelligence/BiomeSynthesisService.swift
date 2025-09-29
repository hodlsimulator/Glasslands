//
//  BiomeSynthesisService.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import Foundation

/// Deterministic "biome recipe" builder from a human-readable seed charm (e.g. RAIN_FOX_PEAKS).
/// If Apple Intelligence / Foundation Models are available later, wire them here behind the same API.
final class BiomeSynthesisService {

    func recipe(for seedCharm: String) -> BiomeRecipe {
        let tokens = seedCharm.uppercased().split(separator: "_")
        let has = { (s: String) in tokens.contains(Substring(s)) }

        let cool = has("RAIN") || has("MIST") || has("MOON") || has("PEAKS")
        let warm = has("SUN") || has("MESA") || has("BLOOM")

        // Noise flavours
        let heightBase = has("PEAKS") ? "ridged" : (has("MESA") ? "billow" : "perlin")
        let moistureBase = has("MIST") ? "billow" : "perlin"

        // Amplitudes and scales
        let heightAmp: Double = has("PEAKS") ? 1.0 : 0.7
        let moistAmp: Double  = (has("MIST") || has("GROVE")) ? 1.0 : 0.6
        let hScale: Double    = has("MESA") ? 2.2 : 1.4
        let mScale: Double    = has("MIST") ? 1.2 : 1.6

        let height = NoiseParams(base: heightBase, octaves: 5, amplitude: heightAmp, scale: hScale)
        let moisture = NoiseParams(base: moistureBase, octaves: 4, amplitude: moistAmp,  scale: mScale)

        // Palettes
        let paletteCool  = ["#8BC7DA","#36667C","#E0F2F6","#F3E2C0","#704B2C"]   // default cool
        let paletteWarm  = ["#F2C14E","#F78154","#FCECC9","#7FB069","#3D405B"]
        let paletteNeut  = ["#A8DADC","#457B9D","#F1FAEE","#E5989B","#6A4C93"]
        let palette = cool ? paletteCool : (warm ? paletteWarm : paletteNeut)

        // One core setpiece for the slice
        let setpieces = [SetpieceDef(name: "glass_beacon", rarity: 0.015)]

        let weatherBias = cool ? "cool" : (warm ? "warm" : "temperate")
        let music = MusicMood(mode: cool ? "dorian" : "ionian", tempo: warm ? 120 : 92)

        return BiomeRecipe(
            height: height,
            moisture: moisture,
            paletteHex: palette,
            faunaTags: [],
            setpieces: setpieces,
            weatherBias: weatherBias,
            music: music,
            seed64: splitmix64(seedCharm)
        )
    }

    // SplitMix64 over an FNV-1a seed of the string to keep results stable but well-spread.
    private func splitmix64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x00000100000001B3
        }
        var z = h &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return z
    }
}
