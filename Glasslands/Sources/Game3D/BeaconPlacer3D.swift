//
//  BeaconPlacer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Places simple beacons.
//  NOTE: No SceneKit physics bodies here — obstacle collision uses hitRadius.
//

import SceneKit
import GameplayKit
import UIKit

struct BeaconPlacer3D {
    static func place(inChunk ci: IVec2,
                      cfg: FirstPersonEngine.Config,
                      noise: NoiseFields,
                      recipe: BiomeRecipe) -> [SCNNode] {

        let tilesX = cfg.tilesX, tilesZ = cfg.tilesZ
        let originTile = IVec2(ci.x * tilesX, ci.y * tilesZ)

        let rarity = recipe.setpieces.first(where: { $0.name == "glass_beacon" })?.rarity ?? 0.015
        let tilesPerChunk = tilesX * tilesZ
        let expected = max(0, Int(round(Double(tilesPerChunk) * rarity)))

        let seed = recipe.seed64 &+ UInt64(bitPattern: Int64(ci.x)) &* 0x9E3779B97F4A7C15
                                 &+ UInt64(bitPattern: Int64(ci.y))

        let rng = GKMersenneTwisterRandomSource(seed: seed)

        var out: [SCNNode] = []
        var placed = 0, attempts = 0

        while placed < expected && attempts < tilesPerChunk * 2 {
            attempts += 1

            let tx = originTile.x + rng.nextInt(upperBound: tilesX)
            let tz = originTile.y + rng.nextInt(upperBound: tilesZ)

            let h = noise.sampleHeight(Double(tx), Double(tz)) / max(0.0001, recipe.height.amplitude)
            let m = noise.sampleMoisture(Double(tx), Double(tz)) / max(0.0001, recipe.moisture.amplitude)
            let s = noise.slope(Double(tx), Double(tz))
            let r = noise.riverMask(Double(tx), Double(tz))

            if h < 0.34 { continue }
            if s > 0.25 { continue }
            if r > 0.55 { continue }

            let isForest = (h < 0.62) && (m > 0.55) && (s < 0.12)
            if isForest || (h >= 0.34 && h < 0.62) {
                let wx = Float(tx) * cfg.tileSize + cfg.tileSize * 0.5
                let wz = Float(tz) * cfg.tileSize + cfg.tileSize * 0.5
                let wy = Float(noise.sampleHeight(Double(tx), Double(tz))) * cfg.heightScale + 0.2

                let n = SCNNode(geometry: beaconGeometry())
                n.position = SCNVector3(wx, wy, wz)
                n.name = "beacon"

                // No physics body. We still expose a radius for obstacle list.
                let radius: CGFloat = 0.18
                n.setValue(radius, forKey: "hitRadius")

                out.append(n)
                placed += 1
            }
        }
        return out
    }

    private static func beaconGeometry() -> SCNGeometry {
        let cyl = SCNCapsule(capRadius: 0.18, height: 0.46)
        let m = SCNMaterial()
        m.emission.contents = UIColor.white.withAlphaComponent(0.85)
        m.diffuse.contents  = UIColor.white.withAlphaComponent(0.2)
        m.lightingModel = .physicallyBased
        cyl.materials = [m]
        return cyl
    }
}
