//
//  SunBillboard.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit

enum SunBillboard {
    @MainActor
    static func makeNode(diameterWorld: CGFloat, emissionIntensity: CGFloat) -> SCNNode {
        let img = SceneKitHelpers.sunSpriteImage(diameter: 192)

        let plane = SCNPlane(width: diameterWorld, height: diameterWorld)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.clear
        m.emission.contents = img
        m.emission.intensity = emissionIntensity
        m.readsFromDepthBuffer = true    // occludes correctly behind terrain
        m.writesToDepthBuffer = false
        plane.firstMaterial = m

        let n = SCNNode(geometry: plane)
        let b = SCNBillboardConstraint()
        b.freeAxes = .all
        n.constraints = [b]
        n.name = "SunBillboard"
        n.castsShadow = false
        n.renderingOrder = -9_990
        return n
    }
}
