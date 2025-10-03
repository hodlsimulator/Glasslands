//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//

//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Convenience for producing a UIImage sky on the main actor.
//

import Foundation
import CoreGraphics
import UIKit

enum SkyGen {
    static let defaultCoverage: Float = 0.34

    @MainActor
    static func skyWithCloudsImage(
        width: Int = 1536,
        height: Int = 768,
        coverage: Float = defaultCoverage,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63
    ) -> UIImage {
        let px = CumulusRenderer.computePixels(
            width: width,
            height: height,
            coverage: coverage,
            edgeSoftness: edgeSoftness,
            seed: seed,
            sunAzimuthDeg: sunAzimuthDeg,
            sunElevationDeg: sunElevationDeg
        )

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

        return UIImage(cgImage: cg)
    }
}
