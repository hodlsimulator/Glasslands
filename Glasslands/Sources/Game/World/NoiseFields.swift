//
//  NoiseFields.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import GameplayKit

final class NoiseFields {
    let height: GKNoise
    let moisture: GKNoise
    private let ampH: Double
    private let ampM: Double
    private let scaleH: Double
    private let scaleM: Double

    init(recipe: BiomeRecipe) {
        func source(_ p: NoiseParams) -> GKNoiseSource {
            switch p.base.lowercased() {
            case "ridged": return GKRidgedNoiseSource(frequency: 1.0, octaveCount: p.octaves, lacunarity: 2.0, seed: Int32(truncatingIfNeeded: recipe.seed64))
            case "billow": return GKBillowNoiseSource(frequency: 1.0, octaveCount: p.octaves, persistence: 0.5, lacunarity: 2.0, seed: Int32(truncatingIfNeeded: recipe.seed64))
            default:       return GKPerlinNoiseSource(frequency: 1.0, octaveCount: p.octaves, persistence: 0.5, lacunarity: 2.0, seed: Int32(truncatingIfNeeded: recipe.seed64))
            }
        }
        height = GKNoise(source(recipe.height))
        moisture = GKNoise(source(recipe.moisture))
        ampH = recipe.height.amplitude
        ampM = recipe.moisture.amplitude
        scaleH = max(1.0, recipe.height.scale)
        scaleM = max(1.0, recipe.moisture.scale)
    }

    // Sample -1..+1 → map to 0..1 & apply amplitude
    func sampleHeight(_ x: Double, _ y: Double) -> Double {
        let v = height.value(atPosition: vector_double2(x/scaleH, y/scaleH))
        return (v * 0.5 + 0.5) * ampH
    }

    func sampleMoisture(_ x: Double, _ y: Double) -> Double {
        let v = moisture.value(atPosition: vector_double2(x/scaleM, y/scaleM))
        return (v * 0.5 + 0.5) * ampM
    }
}
