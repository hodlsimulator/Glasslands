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

        // Inside-out dome
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
        node.scale = SCNVector3(-1, 1, 1) // flip faces inward
        return node
    }

    /// Convenience: if coverage == 0, use a solid blue *colour* instead of an image.
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
        let sphere = SCNSphere(radius: radius)
        sphere.isGeodesic = true
        sphere.segmentCount = 64

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = nil
        m.isDoubleSided = true
        m.cullMode = .back
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.emission.minificationFilter = .linear
        m.emission.magnificationFilter = .linear
        m.emission.mipFilter = .linear

        if coverage <= 0 {
            // Solid, unmistakably blue sky (fastest path; no image sampling).
            m.emission.contents = UIColor(red: 0.22, green: 0.50, blue: 0.92, alpha: 1.0)
        } else {
            let img = SkyGen.skyWithCloudsImage(
                width: width,
                height: height,
                coverage: coverage,
                thickness: thickness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )
            m.emission.contents = img
        }

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        node.scale = SCNVector3(-1, 1, 1)
        return node
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
        if coverage <= 0 {
            guard let sphere = node.geometry as? SCNSphere,
                  let m = sphere.firstMaterial else { return }
            m.emission.contents = UIColor(red: 0.22, green: 0.50, blue: 0.92, alpha: 1.0)
            return
        }
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
