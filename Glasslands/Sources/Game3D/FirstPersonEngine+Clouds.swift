//
//  FirstPersonEngine+Clouds.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cloud impostors (SceneKit shader-modifier path) + maintenance utilities.
//  Cluster groups are oriented manually each frame. The orientation is computed in world space,
//  then converted into the cloud-layer's local space so any parent yaw offsets do not skew
//  billboards and cause backface culling.
//

import SceneKit
import simd
import UIKit
import CoreGraphics

extension FirstPersonEngine {

    // MARK: - Volumetric cloud impostors (shader-modifier path)

    @MainActor
    func enableVolumetricCloudImpostors(_ on: Bool) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        // Remove any leftover constraints inside the cloud layer.
        // Earlier builds used SCNBillboardConstraint on lots of puff nodes; that becomes costly fast.
        layer.enumerateChildNodes { node, _ in
            if node.constraints?.isEmpty == false { node.constraints = nil }
        }

        // Swap materials on puff planes.
        layer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }

            if on {
                // Determine half-size in world units so shader can keep UVs aspect-correct.
                let (hx, hy): (CGFloat, CGFloat) = {
                    if let p = geo as? SCNPlane {
                        return (max(0.001, p.width * 0.5), max(0.001, p.height * 0.5))
                    } else {
                        let bb = geo.boundingBox
                        let w = CGFloat(max(0.001, (bb.max.x - bb.min.x) * 0.5))
                        let h = CGFloat(max(0.001, (bb.max.y - bb.min.y) * 0.5))
                        return (w, h)
                    }
                }()

                let m = CloudImpostorProgram.makeMaterial(halfWidth: hx, halfHeight: hy)

                // Preserve any sprite tint/transparency so the per-band look stays consistent.
                if let old = geo.firstMaterial {
                    m.multiply.contents = old.multiply.contents
                    m.transparency = old.transparency
                }

                geo.firstMaterial = m
            } else {
                // Back to plain billboards.
                for m in geo.materials {
                    m.shaderModifiers = nil
                    m.program = nil
                }
            }
        }

        // The billboard layer is created asynchronously.
        // After swapping materials in, push the sun direction + tuned params now.
        if on { applyCloudSunUniforms() }
    }

    // MARK: - Disabled prewarm (no-op to avoid SceneKit assertion on iOS 26)

    @MainActor
    func prewarmCloudImpostorPipelines() {
        // Intentionally left empty.
        // Avoids calling SCNRenderer.prepare(...) on SCNProgram-backed materials.
    }

    // MARK: - Per-frame uniforms (renderer thread → MainActor)

    /// Called from the render loop with a stable render-time clock.
    /// Movement is driven from `stepUpdateMain(at:)` (cloud conveyor). This function keeps:
    /// - The uniform store fed (time, sun, wind)
    /// - The billboard groups facing the camera (correct under parent yaw)
    /// - The zenith guard applied
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        // Keep the sky anchor co-located with the player so large radii remain stable.
        if skyAnchor.parent == scene.rootNode {
            skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition
        }

        // Update shared volumetric uniforms from render clock.
        VolCloudUniformsStore.shared.update(
            time: Float(t),
            sunDirWorld: simd_normalize(sunDirWorld),
            wind: cloudWind,
            domainOffset: cloudDomainOffset
        )

        // Manual billboard facing (correct even if the layer has a yaw offset).
        orientAllCloudGroupsTowardCamera()

        // Zenith guard with gentle hysteresis (depth read off near straight-up only).
        updateZenithCull(
            depthOffEnter: 1.05, // ~60°
            depthOffExit: 0.95,  // ~54°
            hideEnterRad: 1.50,  // ~86° (very rare)
            hideExitRad: 1.44    // ~82.5°
        )
    }

    // MARK: - Manual group billboarding

    /// Faces each cluster group toward the camera.
    /// Computes desired world orientation, then converts it into the layer's local space
    /// so any parent yaw (used for variety) does not skew billboards.
    @MainActor
    private func orientAllCloudGroupsTowardCamera() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }
        guard let pov = (scnView?.pointOfView ?? camNode) as SCNNode? else { return }

        let camPos = pov.presentation.simdWorldPosition
        let worldUp = simd_float3(0, 1, 0)

        // All cluster groups share the same parent (the layer).
        // Convert world-facing orientation into the parent's local space.
        let parentWorld = layer.presentation.simdWorldTransform
        let c0 = simd_normalize(simd_float3(parentWorld.columns.0.x, parentWorld.columns.0.y, parentWorld.columns.0.z))
        let c1 = simd_normalize(simd_float3(parentWorld.columns.1.x, parentWorld.columns.1.y, parentWorld.columns.1.z))
        let c2 = simd_normalize(simd_float3(parentWorld.columns.2.x, parentWorld.columns.2.y, parentWorld.columns.2.z))
        let parentRot3 = simd_float3x3(columns: (c0, c1, c2))
        let parentRot = simd_quatf(parentRot3)
        let parentInv = simd_inverse(parentRot)

        for g in layer.childNodes {
            let gp = g.presentation.simdWorldPosition

            var forward = camPos - gp
            if simd_length_squared(forward) < 1.0e-10 { continue }
            forward = simd_normalize(forward)

            var right = simd_cross(worldUp, forward)
            if simd_length_squared(right) < 1.0e-8 {
                right = simd_float3(1, 0, 0)
            } else {
                right = simd_normalize(right)
            }

            let up = simd_normalize(simd_cross(forward, right))

            let worldBasis = simd_float3x3(columns: (right, up, forward))
            let qWorld = simd_quatf(worldBasis)

            // Convert world rotation into the layer’s local space.
            g.simdOrientation = simd_mul(parentInv, qWorld)
        }
    }

    @MainActor
    func installVolumetricCloudsIfMissing(
        baseY: CGFloat,
        topY: CGFloat,
        coverage: CGFloat
    ) {
        // Remove any simple cloud dome that might have been installed earlier.
        skyAnchor.childNodes
            .filter { $0.name == "CloudDome" }
            .forEach { $0.removeFromParentNode() }

        // If the volumetric layer already exists, just update its key uniforms.
        if let existing = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: true) {
            if let m = existing.geometry?.firstMaterial {
                m.setValue(baseY, forKey: "baseY")
                m.setValue(topY, forKey: "topY")
                m.setValue(coverage, forKey: "coverage")

                let dir = simd_normalize(sunDirWorld)
                m.setValue(SCNVector3(dir.x, dir.y, dir.z), forKey: "sunDirWorld")
                m.setValue(SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z), forKey: "sunTint")
            }
            return
        }

        // True volumetric vapour path is exclusive: remove billboard sprites if present.
        if let billboards = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            billboards.removeFromParentNode()
        }
        cloudLayerNode = nil
        cloudBillboardNodes.removeAll(keepingCapacity: true)
        cloudClusterGroups.removeAll(keepingCapacity: true)
        cloudClusterCentroidLocal.removeAll(keepingCapacity: true)

        let vol = VolumetricCloudLayer.make(
            radius: CGFloat(cfg.skyDistance),
            baseY: baseY,
            topY: topY,
            coverage: coverage
        )
        skyAnchor.addChildNode(vol)

        if let m = vol.geometry?.firstMaterial {
            let dir = simd_normalize(sunDirWorld)
            m.setValue(SCNVector3(dir.x, dir.y, dir.z), forKey: "sunDirWorld")
            m.setValue(SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z), forKey: "sunTint")
        }
    }

    // MARK: - Cleanup

    @MainActor
    func removeVolumetricDomeIfPresent() {
        skyAnchor.childNodes
            .filter { $0.name == "VolumetricCloudLayer" || $0.name == "CloudDome" }
            .forEach { $0.removeFromParentNode() }
    }
}
