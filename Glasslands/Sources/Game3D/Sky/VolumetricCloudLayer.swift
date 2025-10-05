//
//  VolumetricCloudLayer.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Inside‑out sphere that runs the volumetric cloud SCNProgram.
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

        // Program-backed material for volumetric clouds.
        let mat = VolumetricCloudProgram.makeMaterial()

        // Baseline bounds/coverage.
        mat.setValue(baseY,    forKey: "baseY")
        mat.setValue(topY,     forKey: "topY")
        mat.setValue(coverage, forKey: "coverage")

        // <<< The tuning you asked about goes here >>>
        mat.setValue(0.60 as CGFloat, forKey: "mieG")        // forward scattering
        mat.setValue(2.20 as CGFloat, forKey: "powderK")     // edge “pop”
        mat.setValue(1.15 as CGFloat, forKey: "densityMul")  // overall vapour
        mat.setValue(0.90 as CGFloat, forKey: "stepMul")     // quality/perf
        mat.setValue(1.10 as CGFloat, forKey: "detailMul")   // cauliflower detail
        // <<< end >>>

        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.name = "VolumetricCloudLayer"
        node.castsShadow = false
        node.renderingOrder = -9_990
        return node
    }
}
