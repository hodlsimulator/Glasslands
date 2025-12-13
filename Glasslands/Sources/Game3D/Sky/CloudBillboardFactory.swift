//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Creates SceneKit nodes for a cloud cluster spec. Each puff is a plane with a
//  shader-driven volumetric impostor. Material caching is used to reduce overhead.
//

import SceneKit
import UIKit
import simd

struct CloudBillboardFactory {

    private let atlas: UIImage?

    init(_ atlas: UIImage?) { self.atlas = atlas }

    static func initWithAtlas(_ atlas: UIImage?) -> CloudBillboardFactory {
        CloudBillboardFactory(atlas)
    }

    @inline(__always)
    private static func fract(_ x: Float) -> Float { x - floorf(x) }

    @inline(__always)
    private static func hash01(_ x: Float, _ y: Float, _ z: Float) -> Float {
        // Simple deterministic hash for stable per-puff variation.
        fract(sinf(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453)
    }

    // Material cache keyed by quantised (halfW, halfH) so stretched puffs reuse shaders.
    @MainActor
    private static var materialCache: [UInt64: SCNMaterial] = [:]

    @MainActor
    private func materialFor(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
        // Quantise to reduce cache size.
        let qW = UInt32((halfW * 0.05).rounded(.toNearestOrAwayFromZero) * 20.0)
        let qH = UInt32((halfH * 0.05).rounded(.toNearestOrAwayFromZero) * 20.0)
        let key = (UInt64(qW) << 32) | UInt64(qH)

        if let m = CloudBillboardFactory.materialCache[key] { return m }

        let m = CloudImpostorProgram.makeMaterial(
            halfWidth: halfW,
            halfHeight: halfH
        )
        CloudBillboardFactory.materialCache[key] = m
        return m
    }

    @MainActor
    func makeNode(from spec: CloudClusterSpec) -> SCNNode {

        let group = SCNNode()
        group.name = "CloudCluster"

        // Global scale to keep puffs in a sane range.
        let GLOBAL_SIZE_SCALE: CGFloat = 0.56

        for p in spec.puffs {

            // Stable per-puff stretch (clouds tend to be wider than tall).
            let h0 = CloudBillboardFactory.hash01(p.pos.x * 0.010, p.pos.z * 0.010, p.roll + Float(p.atlasIndex) * 0.73)
            let h1 = CloudBillboardFactory.hash01(p.pos.x * 0.017, p.pos.z * 0.013, p.roll * 0.71 + Float(p.atlasIndex) * 1.91)

            let aspect: CGFloat = 1.00 + 0.85 * CGFloat(h0)          // 1.00 ... 1.85
            let inv: CGFloat = 1.0 / sqrt(max(0.0001, aspect))
            let hMul: CGFloat = (0.78 + 0.22 * CGFloat(h1)) * inv     // keeps area reasonable

            let size = CGFloat(p.size) * GLOBAL_SIZE_SCALE
            let w = size * aspect
            let h = size * hMul

            let plane = SCNPlane(width: w, height: h)
            plane.cornerRadius = 0

            let material = materialFor(halfW: w * 0.5, halfH: h * 0.5)
            plane.firstMaterial = material

            let sprite = SCNNode(geometry: plane)
            sprite.name = "CloudPuff"
            sprite.simdPosition = p.pos
            sprite.eulerAngles.z = p.roll

            // Per-puff opacity and tint.
            sprite.opacity = CGFloat(max(0, min(1, p.opacity)))

            // Tint is applied via multiply (shader outputs white by default).
            if let m = plane.firstMaterial {
                let t = p.tint ?? simd_float3(1, 1, 1)
                m.multiply.contents = UIColor(
                    red: CGFloat(t.x),
                    green: CGFloat(t.y),
                    blue: CGFloat(t.z),
                    alpha: 1.0
                )
            }

            group.addChildNode(sprite)
        }

        return group
    }
}
