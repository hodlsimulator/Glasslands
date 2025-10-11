//
//  FirstPersonEngine+Clouds.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

import SceneKit
import simd
import UIKit
import CoreGraphics

@MainActor
private enum AdvectClock { static var last: TimeInterval = 0 }

extension FirstPersonEngine {
    // MARK: - Volumetric cloud impostors (shader-modifier path)
    @MainActor
    func enableVolumetricCloudImpostors(_ on: Bool) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }

            if on {
                // Half-size so shader can keep UVs aspect-correct.
                let (hx, hy): (CGFloat, CGFloat) = {
                    if let p = g as? SCNPlane {
                        return (max(0.001, p.width * 0.5), max(0.001, p.height * 0.5))
                    } else {
                        let bb = g.boundingBox
                        let w = CGFloat(max(0.001, (bb.max.x - bb.min.x) * 0.5))
                        let h = CGFloat(max(0.001, (bb.max.y - bb.min.y) * 0.5))
                        return (w, h)
                    }
                }()

                let m = CloudImpostorProgram.makeMaterial(halfWidth: hx, halfHeight: hy)

                // Preserve tint/transparency from any existing material.
                if let old = g.firstMaterial {
                    m.multiply.contents = old.multiply.contents
                    m.transparency = old.transparency
                }
                g.firstMaterial = m
            } else {
                // Back to plain billboards
                for m in g.materials {
                    m.shaderModifiers = nil
                    m.program = nil
                }
            }
        }

        // Push the sun/uniforms after swapping
        if on { applyCloudSunUniforms() }
    }

    // MARK: - Prewarm disabled (no-op on iOS 26)
    @MainActor
    func prewarmCloudImpostorPipelines() { }
}
