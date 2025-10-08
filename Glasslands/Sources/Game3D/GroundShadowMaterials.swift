//
//  GroundShadowMaterials.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//

import Foundation
import SceneKit

@MainActor
final class GroundShadowMaterials {
    static let shared = GroundShadowMaterials()
    private let table = NSHashTable<SCNMaterial>.weakObjects()

    func register(_ material: SCNMaterial) {
        if !table.allObjects.contains(where: { $0 === material }) {
            table.add(material)
        }
    }

    func all() -> [SCNMaterial] { table.allObjects }
}
