//
//  SceneryCommon.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit

enum SceneryCommon {
    static func applyLOD(to node: SCNNode, far: CGFloat) {
        if let g = node.geometry {
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: far)]
        }
        node.enumerateChildNodes { child, _ in
            if let g = child.geometry {
                g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: far)]
            }
        }
    }

    static let ldrClampDownFrag = """
    #pragma body
    if (_surface.normal.y < 0.05) {
        _output.color.rgb = min(_output.color.rgb, float3(0.98)) * 0.92;
    }
    """
}

extension UIColor {
    func adjustingHue(by dH: CGFloat, satBy dS: CGFloat, briBy dB: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var hh = (h + dH).truncatingRemainder(dividingBy: 1); if hh < 0 { hh += 1 }
        let ss = max(0, min(1, s + dS))
        let bb = max(0, min(1, b + dB))
        return UIColor(hue: hh, saturation: ss, brightness: bb, alpha: a)
    }
}
