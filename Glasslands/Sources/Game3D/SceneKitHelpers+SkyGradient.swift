//
//  SceneKitHelpers+SkyGradient.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  quirectangular sky gradient tuned to the reference photo.
//

import UIKit
import CoreGraphics

extension SceneKitHelpers {

    @MainActor
    static func equirectSkyGradient(width: Int, height: Int) -> UIImage {
        let W = max(64, width), H = max(32, height)

        UIGraphicsBeginImageContextWithOptions(CGSize(width: W, height: H), false, 1)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        // Reference-matched blues (sRGB)
        let zenith = UIColor(red: 0.30, green: 0.56, blue: 0.96, alpha: 1.0)   // deeper top blue
        let horizon = UIColor(red: 0.88, green: 0.93, blue: 0.99, alpha: 1.0)  // bright near horizon

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
            start: CGPoint(x: 0, y: 0),              // zenith
            end:   CGPoint(x: 0, y: CGFloat(H)),     // horizon
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
