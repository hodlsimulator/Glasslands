//
//  VolumetricCloudLayer.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Inside-out sphere that runs the volumetric vapour program.
//

import SceneKit
import UIKit

enum VolumetricCloudLayer {
    @MainActor
    static func make(
        radius: CGFloat,
        baseY: CGFloat,
        topY: CGFloat,
        coverage: CGFloat
    ) -> SCNNode {
        let sphere = SCNSphere(radius: max(10, radius * 0.98))
        sphere.segmentCount = 96

        let mat = VolumetricCloudProgram.makeMaterial()
        mat.setValue(baseY,    forKey: "baseY")
        mat.setValue(topY,     forKey: "topY")
        mat.setValue(coverage, forKey: "coverage")

        // Tuned for bright, fluffy cumulus
        mat.setValue(0.60 as CGFloat, forKey: "mieG")
        mat.setValue(2.10 as CGFloat, forKey: "powderK")
        mat.setValue(1.15 as CGFloat, forKey: "densityMul")
        mat.setValue(0.85 as CGFloat, forKey: "stepMul")
        mat.setValue(1.10 as CGFloat, forKey: "detailMul")
        mat.setValue(0.0045 as CGFloat, forKey: "puffScale")
        mat.setValue(0.65 as CGFloat,  forKey: "puffStrength")

        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.name = "VolumetricCloudLayer"
        node.castsShadow = false
        node.renderingOrder = -9_990
        return node
    }
}
