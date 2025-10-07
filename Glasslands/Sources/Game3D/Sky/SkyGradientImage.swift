//
//  SkyGradientImage.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Creates a vertical UIImage gradient for SceneKit backgrounds.
//

import UIKit

enum SkyGradientImage {
    static func make(size: CGSize = CGSize(width: 4, height: 1024),
                     top: UIColor = UIColor(red: 0.10, green: 0.30, blue: 0.68, alpha: 1.0),
                     bottom: UIColor = UIColor(red: 0.72, green: 0.85, blue: 0.98, alpha: 1.0)) -> UIImage
    {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cgTop = top.cgColor
            let cgBottom = bottom.cgColor
            let colors = [cgTop, cgBottom] as CFArray
            let locs: [CGFloat] = [1.0, 0.0]
            let space = CGColorSpaceCreateDeviceRGB()
            guard let grad = CGGradient(colorsSpace: space, colors: colors, locations: locs) else { return }
            let p0 = CGPoint(x: size.width / 2.0, y: 0)
            let p1 = CGPoint(x: size.width / 2.0, y: size.height)
            ctx.cgContext.drawLinearGradient(grad, start: p0, end: p1, options: [])
        }
    }
}
