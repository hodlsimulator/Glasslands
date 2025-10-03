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
        sphere.segmentCount = 128

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = skyImage
        m.emission.contents = skyImage
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        m.emission.wrapS = .repeat
        m.emission.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.emission.mipFilter = .linear

        // Render inside of the sphere.
        m.isDoubleSided = false
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Flip horizontally so azimuth aligns with our sun maths.
        let flip = SCNMatrix4MakeScale(-1, 1, 1)
        m.diffuse.contentsTransform = flip
        m.emission.contentsTransform = flip

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        return node
    }
}
