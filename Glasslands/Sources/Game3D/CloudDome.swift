//
//  CloudDome.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Inside-out skydome textured with the generated equirectangular sky.
//

import SceneKit
import UIKit

enum CloudDome {
    static func make(radius: CGFloat, skyImage: UIImage) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.isGeodesic = true
        sphere.segmentCount = 64

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.emission.contents = skyImage
        m.diffuse.contents = nil
        m.emission.minificationFilter = .linear
        m.emission.magnificationFilter = .linear
        m.emission.mipFilter = .linear

        // Robust inside-out: flip geometry, keep normal culling.
        m.isDoubleSided = true
        m.cullMode = .back
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.emission.contentsTransform = SCNMatrix4Identity

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false

        // Flip the sphere so its faces point inward.
        node.scale = SCNVector3(-1, 1, 1)
        return node
    }

    static func make(
        radius: CGFloat,
        coverage: Float,
        thickness: Float = 0.12,
        seed: UInt32 = 424242,
        width: Int = 2048,
        height: Int = 1024,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> SCNNode {
        let img = SkyGen.skyWithCloudsImage(
            width: width,
            height: height,
            coverage: coverage,
            thickness: thickness,
            seed: seed,
            sunAzimuthDeg: sunAzimuthDeg,
            sunElevationDeg: sunElevationDeg
        )
        return make(radius: radius, skyImage: img)
    }

    static func update(_ node: SCNNode, skyImage: UIImage) {
        guard let sphere = node.geometry as? SCNSphere,
              let m = sphere.firstMaterial else { return }
        m.emission.contents = skyImage
    }

    static func update(
        _ node: SCNNode,
        coverage: Float,
        thickness: Float = 0.12,
        seed: UInt32 = 424242,
        width: Int = 2048,
        height: Int = 1024,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) {
        let img = SkyGen.skyWithCloudsImage(
            width: width,
            height: height,
            coverage: coverage,
            thickness: thickness,
            seed: seed,
            sunAzimuthDeg: sunAzimuthDeg,
            sunElevationDeg: sunElevationDeg
        )
        update(node, skyImage: img)
    }
}
