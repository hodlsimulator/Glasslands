//
//  CloudDome+Async.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

//
//  CloudDome+Async.swift
//  Glasslands
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
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // Build pixels/CGImage off the main actor (no UIKit/SceneKit here).
            let cg = SkyGen.skyWithCloudsCGImage(
                width: width,
                height: height,
                coverage: coverage,
                edgeSoftness: edgeSoftness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )

            // Hop to the main actor for UIImage + SceneKit node creation.
            await MainActor.run {
                let img = UIImage(cgImage: cg)
                let node = CloudDome.make(radius: radius, skyImage: img)
                completion(node)
            }
        }
    }
}
