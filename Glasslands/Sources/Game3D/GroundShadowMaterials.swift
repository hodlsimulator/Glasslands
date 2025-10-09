//
//  GroundShadowMaterials.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//

import SceneKit

final class GroundShadowMaterials {
    static let shared = GroundShadowMaterials()
    private let table = NSHashTable<SCNMaterial>.weakObjects()
    private let lock = NSLock()

    func register(_ m: SCNMaterial) {
        lock.lock(); defer { lock.unlock() }
        table.add(m)
    }

    func all() -> [SCNMaterial] {
        lock.lock(); defer { lock.unlock() }
        return table.allObjects
    }
}
