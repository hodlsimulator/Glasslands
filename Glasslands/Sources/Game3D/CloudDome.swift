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

        // Emission-only, with crisp sampling
        m.emission.contents = skyImage
        m.diffuse.contents = nil
        m.emission.minificationFilter = .linear
        m.emission.magnificationFilter = .nearest
        m.emission.mipFilter = .none

        m.isDoubleSided = false
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Match equirect orientation
        m.emission.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        return node
    }
}
