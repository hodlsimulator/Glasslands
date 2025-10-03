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

    /// Build a dome from a ready image (kept for completeness).
    static func make(radius: CGFloat, skyImage: UIImage) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.isGeodesic = true
        sphere.segmentCount = 64

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = skyImage
        m.emission.contents = nil

        // Render only the interior faces (no negative scaling).
        m.isDoubleSided = false
        m.cullMode = .front

        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Proper sampling
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.mipFilter = .linear

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        return node
    }

    /// Primary path: if `coverage == 0`, the dome is a **solid blue colour** (fastest and unambiguous).
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
        m.emission.contents = nil

        // Render only the interior faces; no negative scale required.
        m.isDoubleSided = false
        m.cullMode = .front

        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.mipFilter = .linear

        if coverage <= 0 {
            // **Unmistakably blue**. This path bypasses the procedural image entirely.
            m.diffuse.contents = UIColor(red: 0.22, green: 0.50, blue: 0.92, alpha: 1.0)
        } else {
            m.diffuse.contents = SkyGen.skyWithCloudsImage(
                width: width,
                height: height,
                coverage: coverage,
                thickness: thickness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )
        }

        sphere.firstMaterial = m

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        node.castsShadow = false
        return node
    }

    static func update(_ node: SCNNode, skyImage: UIImage) {
        guard let m = node.geometry?.firstMaterial else { return }
        m.diffuse.contents = skyImage
        m.emission.contents = nil
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
        guard let m = node.geometry?.firstMaterial else { return }
        if coverage <= 0 {
            m.diffuse.contents = UIColor(red: 0.22, green: 0.50, blue: 0.92, alpha: 1.0)
            m.emission.contents = nil
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
        m.diffuse.contents = img
        m.emission.contents = nil
    }
}
