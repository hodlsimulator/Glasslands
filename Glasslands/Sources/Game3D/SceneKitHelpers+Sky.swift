//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Convenience for producing a UIImage sky on the main actor.
//

import UIKit

extension SceneKitHelpers {
    static func skyEquirectGradient(width: Int, height: Int) -> UIImage {
        let w = max(64, width), h = max(32, height)
        let size = CGSize(width: w, height: h)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        let cs = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [
            UIColor(red: 0.62, green: 0.74, blue: 0.92, alpha: 1).cgColor,
            UIColor(red: 0.70, green: 0.82, blue: 0.96, alpha: 1).cgColor,
            UIColor(red: 0.78, green: 0.88, blue: 0.98, alpha: 1).cgColor,
            UIColor(red: 0.86, green: 0.92, blue: 0.99, alpha: 1).cgColor
        ]
        let locs: [CGFloat] = [0.0, 0.35, 0.70, 1.0]
        let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}
