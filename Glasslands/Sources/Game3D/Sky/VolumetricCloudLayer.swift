//
//  VolumetricCloudLayer.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  A single inside-out sphere that renders volumetric clouds with SkyVolumetricClouds.metal.
//

import SceneKit
import CoreGraphics

enum VolumetricCloudLayer {

    @MainActor
    static func make(
        radius: CGFloat,
        baseY: CGFloat,
        topY: CGFloat,
        coverage: CGFloat
    ) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 96

        let mat = VolumetricCloudMaterial.makeMaterial()
        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.name = "VolumetricCloudLayer"
        node.castsShadow = false

        // Must draw after the sky atmosphere, before world.
        node.renderingOrder = -190_000

        // Store defaults in the uniform store so the Metal program has sane values immediately.
        // configure(...) clamps internally; the remaining values are preserved by re-using snapshot defaults.
        let snap = VolCloudUniformsStore.shared.snapshot()
        VolCloudUniformsStore.shared.configure(
            baseY: Float(baseY),
            topY: Float(topY),
            coverage: Float(coverage),
            densityMul: snap.params1.z,
            stepMul: snap.params1.w,
            horizonLift: snap.params2.z,
            detailMul: snap.params2.w,
            puffScale: snap.params3.w,
            puffStrength: snap.params4.x,
            macroScale: snap.params4.z,
            macroThreshold: snap.params4.w
        )

        return node
    }
}
