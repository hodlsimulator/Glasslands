//
//  VolumetricCloudLayer.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Huge inward-facing sphere with a volumetric cloud material.
//  The node is camera-anchored via the engine’s sky anchor.
//

import SceneKit
import UIKit

enum VolumetricCloudLayer {
    @MainActor
    static func make(radius: CGFloat, baseY: CGFloat, topY: CGFloat, coverage: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: max(10, radius * 0.98))
        sphere.segmentCount = 96

        let mat = VolumetricCloudMaterial.makeMaterial()
        mat.setValue(baseY,    forKey: "baseY")
        mat.setValue(topY,     forKey: "topY")
        mat.setValue(coverage, forKey: "coverage")
        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.name = "VolumetricCloudLayer"
        node.castsShadow = false
        node.renderingOrder = -9_990
        return node
    }
}
