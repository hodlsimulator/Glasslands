//
//  SceneKitHelpers+Sun.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Soft, emissive sun sprite used for the visible disc (EDR-enabled).
//

import UIKit
import CoreGraphics

extension SceneKitHelpers {
    static func sunSpriteImage(diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 0                      // device scale
        fmt.preferredRange = .extended     // request extended-range drawing (EDR)
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Extended sRGB colours allow components > 1.0 for hot highlights.
            let esrgb = CGColorSpace(name: CGColorSpace.extendedSRGB) ?? CGColorSpaceCreateDeviceRGB()

            // Warm inner glow values above reference white → visible headroom on HDR panels.
            let inner = CGColor(colorSpace: esrgb, components: [3.2, 2.9, 2.0, 1.0])!
            let outer = CGColor(colorSpace: esrgb, components: [1.0, 0.95, 0.70, 0.0])!

            let grad = CGGradient(colorsSpace: esrgb, colors: [inner, outer] as CFArray, locations: [0.0, 1.0])!
            cg.drawRadialGradient(
                grad,
                startCenter: CGPoint(x: r, y: r), startRadius: 0,
                endCenter: CGPoint(x: r, y: r),   endRadius: r,
                options: []
            )

            // Hot core ellipse with even more headroom.
            let coreRect = CGRect(
                x: size.width * 0.5 - r * 0.58,
                y: size.height * 0.5 - r * 0.58,
                width: r * 1.16,
                height: r * 1.16
            )
            let hotCore = CGColor(colorSpace: esrgb, components: [4.0, 3.6, 2.2, 1.0])!
            cg.setFillColor(hotCore)
            cg.fillEllipse(in: coreRect)
        }
    }
}
