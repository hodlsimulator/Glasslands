//
//  VolumetricCloudLayer.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Inside-out sphere that runs the volumetric vapour program.
//  Excluded from lighting to keep the sun’s shadow frustum tight.
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

        // Geometry
        let sphere = SCNSphere(radius: max(10, radius * 0.98))
        sphere.segmentCount = 96

        // Material + uniforms
        let mat = VolumetricCloudProgram.makeMaterial()
        mat.setValue(baseY, forKey: "baseY")
        mat.setValue(topY, forKey: "topY")

        // Ensure a fuller sky even if callers pass a low coverage.
        // (Keeps performance stable; no extra draw calls.)
        let targetCoverage: CGFloat = max(coverage, 0.74)
        mat.setValue(targetCoverage, forKey: "coverage")

        // Slightly denser/fluffier than before (safe on iOS tile GPUs)
        mat.setValue(0.60 as CGFloat,  forKey: "mieG")
        mat.setValue(2.10 as CGFloat,  forKey: "powderK")
        mat.setValue(1.25 as CGFloat,  forKey: "densityMul")   // was 1.15
        mat.setValue(0.85 as CGFloat,  forKey: "stepMul")
        mat.setValue(1.08 as CGFloat,  forKey: "detailMul")    // was 1.10
        mat.setValue(0.0043 as CGFloat, forKey: "puffScale")   // was 0.0045
        mat.setValue(0.74 as CGFloat,  forKey: "puffStrength") // was 0.65

        sphere.firstMaterial = mat

        // Node
        let node = SCNNode(geometry: sphere)
        node.name = "VolumetricCloudLayer"
        node.castsShadow = false
        node.categoryBitMask = 0        // exclude from lights
        node.renderingOrder = -9_990
        return node
    }
}
