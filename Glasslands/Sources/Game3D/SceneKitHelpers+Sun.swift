//
//  SceneKitHelpers+Sun.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Soft, emissive sun sprite used for the visible disc.
//

import UIKit
import CoreGraphics

extension SceneKitHelpers {
    static func sunSpriteImage(diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }

        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        let cs = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [
            UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95).cgColor,
            UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor
        ]
        let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!

        ctx.drawRadialGradient(
            grad,
            startCenter: CGPoint(x: r, y: r),
            startRadius: 0,
            endCenter: CGPoint(x: r, y: r),
            endRadius: r,
            options: []
        )

        // Hot core
        let coreRect = CGRect(
            x: size.width * 0.5 - r * 0.58,
            y: size.height * 0.5 - r * 0.58,
            width: r * 1.16,
            height: r * 1.16
        )
        ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: coreRect)

        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}
