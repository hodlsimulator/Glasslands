//
//  CloudDome+Async.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import SceneKit
import UIKit

extension CloudDome {
    static func makeAsync(
        radius: CGFloat,
        coverage: Float = 0.34,
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
            let node = CloudDome.make(radius: radius, skyImage: img)
            DispatchQueue.main.async { completion(node) }
        }
    }
}
