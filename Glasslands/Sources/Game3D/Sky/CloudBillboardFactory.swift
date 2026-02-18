//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Creates SceneKit nodes for a cloud cluster spec.
//
//  Key change:
//  - Supports "shadow proxy" clusters (no puff planes), keeping only centroid + radius.
//    This preserves the cloud shadow map inputs without rendering hundreds of impostor quads.
//

import SceneKit
import UIKit
import simd

struct CloudBillboardFactory {

    private let atlas: UIImage?

    init(_ atlas: UIImage?) {
        self.atlas = atlas
    }

    static func initWithAtlas(_ atlas: UIImage?) -> CloudBillboardFactory {
        CloudBillboardFactory(atlas)
    }

    @inline(__always)
    private static func fract(_ x: Float) -> Float {
        x - floorf(x)
    }

    @inline(__always)
    private static func hash01(_ x: Float, _ y: Float, _ z: Float) -> Float {
        fract(sinf(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453)
    }

    // Material cache keyed by quantised (halfW, halfH) so stretched puffs reuse shaders.
    @MainActor
    private static var materialCache: [UInt64: SCNMaterial] = [:]

    @MainActor
    private func materialFor(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
        let qW = UInt32((halfW * 0.05).rounded(.toNearestOrAwayFromZero) * 20.0)
        let qH = UInt32((halfH * 0.05).rounded(.toNearestOrAwayFromZero) * 20.0)
        let key = (UInt64(qW) << 32) | UInt64(qH)

        if let m = CloudBillboardFactory.materialCache[key] {
            return m
        }

        let m = CloudImpostorProgram.makeMaterial(halfWidth: halfW, halfHeight: halfH)
        CloudBillboardFactory.materialCache[key] = m
        return m
    }

    @MainActor
    func makeNode(from spec: CloudClusterSpec, renderPuffs: Bool) -> SCNNode {
        let group = SCNNode()
        group.name = "CloudCluster"

        // Compute centroid in world space.
        var centroid = simd_float3.zero
        if !spec.puffs.isEmpty {
            for p in spec.puffs { centroid += p.pos }
            centroid /= Float(spec.puffs.count)
        }
        group.simdPosition = centroid

        // Cached per-cluster XZ radius used by the cloud shadow map (SunDiffusion).
        var maxRadXZ: Float = 0

        // Shadow-only cluster: no geometry, but keep a child marker so any centroid code
        // that assumes a non-empty child list never divides by zero.
        if renderPuffs == false {
            for p in spec.puffs {
                let localPos = p.pos - centroid
                let centreDist = simd_length(simd_float2(localPos.x, localPos.z))
                let puffR = 0.5 * p.size
                maxRadXZ = max(maxRadXZ, centreDist + puffR)
            }

            let marker = SCNNode()
            marker.name = "CloudPuffProxy"
            marker.simdPosition = .zero
            group.addChildNode(marker)

            group.setValue(NSNumber(value: maxRadXZ), forKey: "gl_clusterRadius")
            return group
        }

        // Full render path (original behaviour).
        let GLOBAL_SIZE_SCALE: CGFloat = 0.56

        for p in spec.puffs {
            let h0 = CloudBillboardFactory.hash01(
                p.pos.x * 0.010,
                p.pos.z * 0.010,
                p.roll + Float(p.atlasIndex) * 0.73
            )
            let h1 = CloudBillboardFactory.hash01(
                p.pos.x * 0.017,
                p.pos.z * 0.013,
                p.roll * 0.71 + Float(p.atlasIndex) * 1.91
            )

            let aspect: CGFloat = 1.00 + 0.85 * CGFloat(h0)
            let inv: CGFloat = 1.0 / sqrt(max(0.0001, aspect))
            let hMul: CGFloat = (0.78 + 0.22 * CGFloat(h1)) * inv

            let size = CGFloat(p.size) * GLOBAL_SIZE_SCALE
            let w = size * aspect
            let h = size * hMul

            let plane = SCNPlane(width: w, height: h)
            plane.cornerRadius = 0

            let material = materialFor(halfW: w * 0.5, halfH: h * 0.5)
            plane.firstMaterial = material

            let sprite = SCNNode(geometry: plane)
            sprite.name = "CloudPuff"

            let localPos = p.pos - centroid
            sprite.simdPosition = localPos
            sprite.eulerAngles.z = p.roll

            let centreDist = simd_length(simd_float2(localPos.x, localPos.z))
            let puffR = 0.5 * Float(max(w, h))
            maxRadXZ = max(maxRadXZ, centreDist + puffR)

            sprite.opacity = CGFloat(max(0, min(1, p.opacity)))

            // Material instances are shared via size-quantized cache. Do not mutate per-puff
            // color state on the shared material, or one random puff can tint many others.
            // Keep cloud tint neutral in shader/uniform space to avoid sporadic outliers.

            group.addChildNode(sprite)
        }

        group.setValue(NSNumber(value: maxRadXZ), forKey: "gl_clusterRadius")
        return group
    }
}
