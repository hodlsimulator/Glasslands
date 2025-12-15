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

extension FirstPersonEngine {

    // MARK: - Volumetric cloud impostors (SceneKit shader-modifier path) + maintenance utilities.

    @MainActor
    func enableVolumetricCloudImpostors(_ enabled: Bool) {
        guard let layer = cloudLayerNode ?? skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        cloudLayerNode = layer
        cloudClusterGroups = layer.childNodes

        cloudBillboardNodes.removeAll(keepingCapacity: true)

        layer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry, geo is SCNPlane else { return }

            cloudBillboardNodes.append(node)

            if enabled {
                let hw = CGFloat((node.value(forKey: "halfW") as? NSNumber)?.floatValue ?? 1100)
                let hh = CGFloat((node.value(forKey: "halfH") as? NSNumber)?.floatValue ?? 620)

                let m = CloudImpostorProgram.makeMaterial(
                    halfWidth: hw,
                    halfHeight: hh,
                    quality: 0.60,
                    sunDir: sunDirWorld
                )
                geo.firstMaterial = m
            }

            // Cluster groups are oriented manually; per-puff constraints are removed.
            node.constraints = nil
        }
    }

    // MARK: - Render-time tick (called by proxy on MainActor)

    @MainActor
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        // Update the uniform store (thread-safe; driven by render-time clock).
        VolCloudUniformsStore.shared.update(
            time: Float(t),
            sunDirWorld: sunDirWorld,
            wind: cloudWind,
            domainOffset: cloudDomainOffset
        )

        // Orient cluster groups once per frame.
        orientAllCloudGroupsTowardCamera()

        // Apply zenith cull (depth read toggle) when crossing the threshold.
        updateZenithCull()

        // Keep sky anchored to player.
        if skyAnchor.parent == scene.rootNode {
            skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition
        }

        // Cloud sun-uniforms are updated by applySunDirection(...) in FirstPersonEngine+Sky.swift.
    }

    // MARK: - Orientation

    @MainActor
    private func orientAllCloudGroupsTowardCamera() {
        guard let layer = cloudLayerNode ?? skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }
        cloudLayerNode = layer

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPosW = pov.simdWorldPosition

        let parentW = layer.presentation.simdWorldTransform
        let c0 = simd_float3(parentW.columns.0.x, parentW.columns.0.y, parentW.columns.0.z)
        let c1 = simd_float3(parentW.columns.1.x, parentW.columns.1.y, parentW.columns.1.z)
        let c2 = simd_float3(parentW.columns.2.x, parentW.columns.2.y, parentW.columns.2.z)
        let parentRot = simd_quatf(simd_float3x3(columns: (c0, c1, c2)))
        let parentInv = simd_inverse(parentRot)

        let groups = !cloudClusterGroups.isEmpty ? cloudClusterGroups : layer.childNodes
        if cloudClusterGroups.isEmpty {
            cloudClusterGroups = groups
        }

        for g in groups {
            let gp = g.presentation.simdWorldPosition
            let fwdW = simd_normalize(camPosW - gp)

            let upW = simd_float3(0, 1, 0)
            let rightW = simd_normalize(simd_cross(upW, fwdW))
            let up2W = simd_normalize(simd_cross(fwdW, rightW))

            let rotW = simd_float3x3(columns: (rightW, up2W, fwdW))
            let rotLocal = parentInv * simd_quatf(rotW)
            g.simdOrientation = rotLocal
        }
    }
}

@MainActor
extension FirstPersonEngine {

    @MainActor
    func removeVolumetricDomeIfPresent() {
        // The current sky stack uses billboard cumulus (raymarched impostor puffs).
        // Any leftover volumetric dome can cover the whole sky and is a common source
        // of the "magenta sky" fallback when its shader path fails to compile.
        //
        // Keep this removal conservative and name-based so it is safe across resets.
        if let dome = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: true) {
            dome.removeFromParentNode()
        }

        scene.rootNode.childNodes
            .filter { $0.name == "VolumetricCloudLayer" }
            .forEach { $0.removeFromParentNode() }
    }

    func installVolumetricCloudsIfMissing(baseY: CGFloat, topY: CGFloat, coverage: CGFloat) {
        // Scattered volumetric cumulus mode is intended to run without the billboard layer.
        if let layer = cloudLayerNode ?? skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: false) {
            layer.removeFromParentNode()
        }

        cloudLayerNode = nil
        cloudBillboardNodes.removeAll(keepingCapacity: true)
        cloudClusterGroups.removeAll(keepingCapacity: true)
        cloudClusterCentroidLocal.removeAll(keepingCapacity: true)

        if let existing = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false) {
            if let m = existing.geometry?.firstMaterial {
                m.setValue(baseY, forKey: "baseY")
                m.setValue(topY, forKey: "topY")
                m.setValue(coverage, forKey: "coverage")
            }
            return
        }

        let dome = VolumetricCloudLayer.make(
            radius: CGFloat(cfg.skyDistance),
            baseY: baseY,
            topY: topY,
            coverage: coverage
        )
        skyAnchor.addChildNode(dome)
    }
}
