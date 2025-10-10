//
//  TreeMaterials.swift
//  Glasslands
//
//  Created by . . on 10/10/25.
//

import SceneKit
import UIKit

enum TreeMaterials {

    static func barkMaterial(colour: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = colour
        m.metalness.contents = 0.0
        m.roughness.contents = 1.0
        m.isDoubleSided = false
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        return m
    }

    /// Alpha *test* leaves: writes depth like opaque, so clouds don’t render in front.
    static func leafMaterial(texture: UIImage, alphaCutoff: Float = 0.35) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.isDoubleSided = true
        m.diffuse.contents = texture
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.shaderModifiers = [.fragment: leafAlphaTestFrag]
        m.setValue(NSNumber(value: alphaCutoff), forKey: "alphaCutoff")
        return m
    }

    /// Simple leaf texture (ellipse + subtle vein). Transparent background.
    static func makeLeafTexture(colour: UIColor) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            cg.setFillColor(UIColor.clear.cgColor)
            cg.fill(rect)

            let path = UIBezierPath(ovalIn: rect.insetBy(dx: 12, dy: 22))
            cg.saveGState()
            cg.addPath(path.cgPath)
            cg.clip()

            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            let cs = CGColorSpaceCreateDeviceRGB()
            let c1 = CGColor(colorSpace: cs, components: [r * 0.90, g * 0.90, b * 0.90, 1])!
            let c2 = CGColor(colorSpace: cs, components: [r * 1.08, g * 1.08, b * 1.00, 1])!
            let grad = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY),
                                  end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            cg.restoreGState()

            cg.setStrokeColor(UIColor(white: 0, alpha: 0.25).cgColor)
            cg.setLineWidth(2)
            cg.move(to: CGPoint(x: rect.midX, y: rect.minY + 26))
            cg.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 26))
            cg.strokePath()
        }
    }

    private static let leafAlphaTestFrag = """
    #pragma arguments
    float alphaCutoff;
    #pragma body
    if (_output.color.a < alphaCutoff) { discard_fragment(); }
    """
}
