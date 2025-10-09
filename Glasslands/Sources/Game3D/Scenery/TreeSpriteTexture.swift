//
//  TreeSpriteTexture.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Procedural tree texture (PNG with alpha). Used only as a fallback.
//

import UIKit
import CoreGraphics

enum TreeSpriteTexture {
    @MainActor
    static func make(
        size: CGSize = CGSize(width: 320, height: 480),
        leaf: UIColor,
        trunk: UIColor,
        seed: UInt32
    ) -> UIImage {
        let W = max(64, Int(size.width))
        let H = max(96, Int(size.height))

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 1

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setBlendMode(.normal)

            var s = seed == 0 ? 1 : Int(seed)
            @inline(__always) func frand() -> CGFloat {
                s = 1664525 &* s &+ 1013904223
                return CGFloat((s >> 8) & 0x00FF_FFFF) * (1.0 / 16_777_216.0)
            }

            let crown = CGRect(
                x: CGFloat(W) * 0.15,
                y: CGFloat(H) * 0.06,
                width: CGFloat(W) * 0.70,
                height: CGFloat(H) * 0.62
            )

            var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 1
            leaf.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
            let darken = 0.84 + 0.10 * frand()
            let topTint = UIColor(red: lr, green: lg, blue: lb, alpha: 1)
            let baseTint = UIColor(red: lr * darken, green: lg * darken, blue: lb * darken, alpha: 1)
            let cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: cs, colors: [topTint.cgColor, baseTint.cgColor] as CFArray, locations: [0, 1])!

            cg.saveGState()
            let crownClip = UIBezierPath(roundedRect: crown, cornerRadius: crown.width * 0.48)
            cg.addPath(crownClip.cgPath)
            cg.clip()
            cg.drawLinearGradient(
                grad,
                start: CGPoint(x: crown.midX, y: crown.minY),
                end: CGPoint(x: crown.midX, y: crown.maxY),
                options: []
            )
            cg.restoreGState()

            @inline(__always) func adjust(_ c: UIColor, dH: CGFloat, dS: CGFloat, dB: CGFloat) -> UIColor {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                var hh = (h + dH).truncatingRemainder(dividingBy: 1); if hh < 0 { hh += 1 }
                return UIColor(hue: hh, saturation: max(0, min(1, s + dS)), brightness: max(0, min(1, b + dB)), alpha: a)
            }

            let blobs = 12 + Int(frand() * 10.0)
            for _ in 0..<blobs {
                let cx = crown.minX + frand() * crown.width
                let cy = crown.minY + frand() * crown.height
                let r  = crown.width * (0.07 + 0.11 * frand())
                let rect = CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r)
                let alpha: CGFloat = 0.60 + 0.30 * frand()
                let tint = adjust(topTint,
                                  dH: (frand() - 0.5) * 0.05,
                                  dS: (frand() - 0.5) * 0.07,
                                  dB: (frand() - 0.5) * 0.07)
                cg.setFillColor(tint.withAlphaComponent(alpha).cgColor)
                cg.fillEllipse(in: rect)
            }

            // Trunk
            let tW = max(6.0, CGFloat(W) * 0.08)
            let tH = CGFloat(H) * 0.22
            let tRect = CGRect(
                x: CGFloat(W) * 0.5 - tW * 0.5,
                y: crown.maxY - tH * 0.08,
                width: tW,
                height: tH
            )
            cg.setFillColor(trunk.cgColor)
            let trunkPath = UIBezierPath(roundedRect: tRect, cornerRadius: tW * 0.22).cgPath
            cg.addPath(trunkPath)
            cg.fillPath()

            // Alpha-safe 2-px transparent frame to avoid clamp/mip artefacts
            cg.setBlendMode(.clear)
            cg.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: 2))
            cg.fill(CGRect(x: 0, y: CGFloat(H) - 2, width: CGFloat(W), height: 2))
            cg.fill(CGRect(x: 0, y: 0, width: 2, height: CGFloat(H)))
            cg.fill(CGRect(x: CGFloat(W) - 2, y: 0, width: 2, height: CGFloat(H)))
        }
    }
}
