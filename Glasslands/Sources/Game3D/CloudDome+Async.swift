//
//  CloudDome+Async.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

import SceneKit
import UIKit
import CoreGraphics

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
        completion: @Sendable @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // Pure compute off the main actor (free function, no actor isolation).
            let px = renderCumulusPixels(
                width: width,
                height: height,
                coverage: coverage,
                edgeSoftness: edgeSoftness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )

            // Hop to main actor for UIImage + SceneKit node creation.
            await MainActor.run {
                let bpr = px.width * 4
                let data = CFDataCreate(nil, px.rgba, px.rgba.count)!
                let provider = CGDataProvider(data: data)!
                let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let cg = CGImage(
                    width: px.width,
                    height: px.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: bpr,
                    space: cs,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                )!
                let img = UIImage(cgImage: cg)
                let node = CloudDome.make(radius: radius, skyImage: img)
                completion(node)
            }
        }
    }
}
