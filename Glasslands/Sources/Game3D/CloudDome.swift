//
//  CloudDome.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Inside-out skydome textured with the generated equirectangular sky.
//

//
//  CloudDome.swift
//  Glasslands
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
        m.isDoubleSided = false
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false

        // Flip horizontally so azimuth matches the generator’s convention.
        let flip = SCNMatrix4MakeScale(-1, 1, 1)
        m.diffuse.contentsTransform = flip
        m.emission.contentsTransform = flip

        sphere.firstMaterial = m
        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        return node
    }

    /// Async builder to avoid any chance of main-thread hitching.
    static func makeAsync(
        radius: CGFloat,
        coverage: Float = SkyGen.defaultCoverage,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        width: Int = 1280,
        height: Int = 640,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63,
        completion: @escaping (SCNNode) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = SkyGen.skyWithCloudsImage(
                width: width,
                height: height,
                coverage: coverage,
                edgeSoftness: edgeSoftness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )
            let node = make(radius: radius, skyImage: img)
            DispatchQueue.main.async {
                completion(node)
            }
        }
    }
}
