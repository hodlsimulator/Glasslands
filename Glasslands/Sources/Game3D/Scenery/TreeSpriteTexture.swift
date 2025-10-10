//
//  TreeSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Lightweight helpers to load and prepare canopy sprites for 3D trees.
//  Uses Assets.xcassets tree images when available; otherwise falls back
//  to a procedural leaf-blob image. Crops out the lower trunk portion of
//  the 2D sprite so the 3D cylinder trunk isn’t duplicated.
//

import UIKit
import GameplayKit

enum TreeSpriteTexture {
    enum Kind { case broadleaf, conifer }

    static func canopyImage(for kind: Kind,
                            palette: [UIColor],
                            rng: inout RandomAdaptor) -> UIImage
    {
        let broadleafNames = [
            "glasslands_tree_broadleaf_A",
            "glasslands_tree_broadleaf_B",
            "glasslands_tree_acacia_A",
        ]
        let coniferNames = [
            "glasslands_tree_conifer_A",
            "glasslands_tree_conifer_B",
            "glasslands_tree_winter_A",
        ]
        let names = (kind == .broadleaf) ? broadleafNames : coniferNames
        let name  = names[Int.random(in: 0..<names.count, using: &rng)]

        // Robust lookup from the main bundle (asset catalog-backed).
        let loaded: UIImage? =
            UIImage(named: name, in: .main, compatibleWith: nil)
            ?? UIImage(named: name)

        if let img = loaded {
            // Remove the bottom slice so the 3D cylinder trunk isn’t duplicated.
            // Broadleaf assets include a sizeable 2D trunk; conifers don’t.
            let keepTop: CGFloat = (kind == .broadleaf) ? 0.70 : 0.98
            return cropTopPortion(of: img, keepTopFraction: keepTop)
        }

        // Procedural fallback – colour comes from the palette.
        let leafBase = palette.indices.contains(2) ? palette[2] :
                       UIColor(red: 0.28, green: 0.60, blue: 0.34, alpha: 1)
        return proceduralCanopyBlob(diameter: 384, tint: leafBase, rng: &rng)
    }

    private static func proceduralCanopyBlob(diameter: Int,
                                             tint: UIColor,
                                             rng: inout RandomAdaptor) -> UIImage
    {
        let d = max(32, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 1

        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()

            var tR: CGFloat = 1, tG: CGFloat = 1, tB: CGFloat = 1, tA: CGFloat = 1
            tint.getRed(&tR, green: &tG, blue: &tB, alpha: &tA)

            let inner = CGColor(colorSpace: cs, components: [tR * 0.95, tG * 0.95, tB * 0.95, 1.0])!
            let outer = CGColor(colorSpace: cs, components: [tR * 0.80, tG * 0.80, tB * 0.80, 0.0])!
            let grad = CGGradient(colorsSpace: cs, colors: [inner, outer] as CFArray, locations: [0.0, 1.0])!
            cg.drawRadialGradient(grad,
                                  startCenter: CGPoint(x: r, y: r),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: r, y: r),
                                  endRadius: r,
                                  options: [])

            let discCount = Int.random(in: 28...42, using: &rng)
            for _ in 0..<discCount {
                let rr = CGFloat.random(in: r*0.08...r*0.22, using: &rng)
                let a  = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                let d  = CGFloat.random(in: 0...(r * 0.55), using: &rng)
                let cx = r + cos(a) * d
                let cy = r + sin(a) * d
                let shade = CGFloat.random(in: 0.85...1.10, using: &rng)
                cg.setFillColor(UIColor(red: tR*shade, green: tG*shade, blue: tB*shade, alpha: 0.25).cgColor)
                cg.fillEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
            }
        }
    }

    private static func cropTopPortion(of image: UIImage, keepTopFraction: CGFloat) -> UIImage {
        let frac = max(0.1, min(1.0, keepTopFraction))
        let scale = image.scale
        let fullW = Int(image.size.width  * scale)
        let fullH = Int(image.size.height * scale)
        let keepH = Int(CGFloat(fullH) * frac)

        let rect = CGRect(x: 0, y: 0, width: fullW, height: keepH)
        guard let cg = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}
