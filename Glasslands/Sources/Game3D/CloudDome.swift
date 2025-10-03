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
        sphere.segmentCount = 64  // was 128

        let m = SCNMaterial()
        m.lightingModel = .constant

        // Emission-only to avoid double sampling the sky texture
        m.emission.contents = skyImage
        m.diffuse.contents = nil
        m.emission.mipFilter = .linear

        m.isDoubleSided = false
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Flip horizontally so azimuth aligns with sun maths
        let flip = SCNMatrix4MakeScale(-1, 1, 1)
        m.emission.contentsTransform = flip

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        return node
    }
}
