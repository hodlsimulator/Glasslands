//
//  TreeLibrary3D.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Prototype cache so we clone prebuilt, flattened trees (shared geometry/materials).
//

import SceneKit
import GameplayKit
import UIKit

enum TreeLibrary3D {
    private static var cacheKey: String?
    private static var protos: [(node: SCNNode, hitR: CGFloat)] = []

    @MainActor
    static func ensureWarm(palette: [UIColor]) {
        let key = paletteKey(palette)
        if cacheKey == key && !protos.isEmpty { return }
        cacheKey = key
        protos.removeAll(keepingCapacity: true)

        let src = GKMersenneTwisterRandomSource(seed: 0xC0FF_EE11)   // ← changed var→let
        var rng = RandomAdaptor(src)

        // 8 prototypes (4 conifer, 4 broadleaf)
        for _ in 0..<4 { protos.append(TreeBuilder3D.makePrototype(palette: palette, rng: &rng, prefer: .conifer)) }
        for _ in 0..<4 { protos.append(TreeBuilder3D.makePrototype(palette: palette, rng: &rng, prefer: .broadleaf)) }
    }

    @MainActor
    static func instance(using rng: inout RandomAdaptor) -> (SCNNode, CGFloat) {
        precondition(!protos.isEmpty, "Call TreeLibrary3D.ensureWarm(palette:) first.")
        let i = Int.random(in: 0..<protos.count, using: &rng)
        let proto = protos[i]
        let node = proto.node.clone()
        let s = CGFloat.random(in: 0.88...1.15, using: &rng)
        node.scale = SCNVector3(s, s, s)
        node.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
        return (node, proto.hitR * s)
    }

    private static func paletteKey(_ palette: [UIColor]) -> String {
        palette.map { c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%04X%04X%04X", Int(r*4095), Int(g*4095), Int(b*4095))
        }.joined(separator: "-")
    }
}
