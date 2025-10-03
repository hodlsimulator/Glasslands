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

        // Emission-only keeps it cheap; set filters on the *property*.
        m.emission.contents = skyImage
        m.diffuse.contents = nil
        m.emission.minificationFilter = .linear
        m.emission.magnificationFilter = .linear
        m.emission.mipFilter = .linear

        // Render inside of the sphere
        m.isDoubleSided = false
        m.cullMode = .front

        // No depth interaction
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Flip horizontally so azimuth aligns with sun maths
        m.emission.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        return node
    }
}
