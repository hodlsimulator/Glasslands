//
//  MushroomBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import GameplayKit

enum MushroomBuilder {
    static func makeMushroomPatchNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()
        let count = Int.random(in: 3...6, using: &rng)
        let stemColour = UIColor(white: 0.90, alpha: 1.0)
        let capBase = palette.indices.contains(0) ? palette[0] : UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1)

        for _ in 0..<count {
            let stemH: CGFloat = CGFloat.random(in: 0.10...0.18, using: &rng)
            let stemR: CGFloat = CGFloat.random(in: 0.015...0.028, using: &rng)
            let capR: CGFloat = CGFloat.random(in: 0.04...0.08, using: &rng)

            let stem = SCNCylinder(radius: stemR, height: stemH)
            let stemM = SCNMaterial()
            stemM.lightingModel = .physicallyBased
            stemM.diffuse.contents = stemColour
            stemM.roughness.contents = 0.95
            stem.materials = [stemM]

            let cap = SCNSphere(radius: capR)
            cap.segmentCount = 12
            let capM = SCNMaterial()
            capM.lightingModel = .physicallyBased
            capM.diffuse.contents = SceneryCommon.adjust(
                capBase,
                dH: CGFloat.random(in: -0.06...0.06, using: &rng),
                dS: CGFloat.random(in: -0.12...0.12, using: &rng),
                dB: CGFloat.random(in: -0.05...0.05, using: &rng)
            )
            capM.roughness.contents = 0.85
            cap.materials = [capM]

            let stemN = SCNNode(geometry: stem)
            stemN.position = SCNVector3(0, stemH * 0.5, 0)
            let capN = SCNNode(geometry: cap)
            capN.position = SCNVector3(0, stemH + capR * 0.35, 0)

            let m = SCNNode()
            m.addChildNode(stemN)
            m.addChildNode(capN)
            m.position = SCNVector3(
                Float.random(in: -0.20...0.20, using: &rng),
                0.0,
                Float.random(in: -0.20...0.20, using: &rng)
            )
            node.addChildNode(m)
        }
        node.categoryBitMask = 0x00000002
        SceneryCommon.applyLOD(to: node, far: 70)
        return node
    }
}
