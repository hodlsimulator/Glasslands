//
//  SceneKitHelpers+SkyGradient.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import UIKit
import CoreGraphics

extension SceneKitHelpers {
    @MainActor
    static func equirectSkyGradient(width: Int, height: Int) -> UIImage {
        let W = max(64, width), H = max(32, height)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: W, height: H), false, 1)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        let zenith  = UIColor(red: 0.50, green: 0.74, blue: 0.92, alpha: 1.0)
        let horizon = UIColor(red: 0.86, green: 0.93, blue: 0.98, alpha: 1.0)

        var zR: CGFloat = 1, zG: CGFloat = 1, zB: CGFloat = 1, zA: CGFloat = 1
        var hR: CGFloat = 1, hG: CGFloat = 1, hB: CGFloat = 1, hA: CGFloat = 1
        zenith.getRed(&zR, green: &zG, blue: &zB, alpha: &zA)
        horizon.getRed(&hR, green: &hG, blue: &hB, alpha: &hA)

        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(
            colorsSpace: cs,
            colors: [UIColor(red: zR, green: zG, blue: zB, alpha: zA).cgColor,
                     UIColor(red: hR, green: hG, blue: hB, alpha: hA).cgColor] as CFArray,
            locations: [0.0, 1.0]
        )!

        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: 0, y: 0),        // zenith
            end:   CGPoint(x: 0, y: CGFloat(H)), // horizon
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    // Alias for the name used in buildSky()
    @MainActor
    static func skyEquirectGradient(width: Int, height: Int) -> UIImage {
        equirectSkyGradient(width: width, height: height)
    }
}
