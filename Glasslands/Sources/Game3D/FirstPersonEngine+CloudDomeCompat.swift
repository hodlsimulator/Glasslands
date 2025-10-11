//
//  FirstPersonEngine+CloudDomeCompat.swift
//  Glasslands
//
//  Created by . . on 10/12/25.
//

import SceneKit

@MainActor
extension FirstPersonEngine {
    func removeVolumetricDomeIfPresent() {
        let candidates = ["VolumetricDome", "CloudDome", "SkyDome"]
        for name in candidates {
            if let node = skyAnchor.childNode(withName: name, recursively: true) {
                node.removeFromParentNode()
            }
        }
    }
}
