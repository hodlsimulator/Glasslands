//
//  FirstPersonEngine+ZenithCull.swift
//  Glasslands
//
//  Created by . . on 10/12/25.
//
//  Pitch-aware guards for the billboard cloud layer that do NOT alter billboard
//  orientation (keeps .all for visuals). Near the zenith we:
//    1) turn OFF readsFromDepthBuffer (with hysteresis) to avoid tile-GPU stalls.
//    2) only very near straight up, hide the layer as a belt-and-braces fallback.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    /// Update zenith guards for the cloud billboard layer.
    ///
    /// - Parameters:
    ///   - depthOffEnter:  when pitch exceeds this (radians), disable depth reads.
    ///   - depthOffExit:   when pitch drops below this, re-enable depth reads.
    ///   - hideEnterRad:   only very close to straight up, hide the whole layer.
    ///   - hideExitRad:    show the layer again after pulling back below this.
    ///
    /// π/2 = 1.5708 rad. Defaults chosen to keep visuals unchanged in normal play.
    @MainActor
    func updateZenithCull(
        depthOffEnter: Float = 1.05, // ~60°
        depthOffExit:  Float = 0.95, // ~54°
        hideEnterRad:  Float = 1.35, // ~77° (rarely hit)
        hideExitRad:   Float = 1.25  // ~72°
    ) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        // 0) If we don’t have any geometry yet, nothing to do.
        var anyMaterial: SCNMaterial?
        if let g = layer.childNodes.first?.geometry { anyMaterial = g.firstMaterial }
        if anyMaterial == nil {
            var found: SCNMaterial?
            layer.enumerateChildNodes { n, stop in
                if let m = n.geometry?.firstMaterial { found = m; stop.pointee = true }
            }
            if found == nil { return }
            anyMaterial = found
        }

        // 1) Hide/show the whole layer very near the zenith (hysteresis).
        let isLookingUp = pitch > 0
        let wasHidden = layer.isHidden
        if wasHidden {
            if !isLookingUp || pitch < hideExitRad { layer.isHidden = false }
        } else {
            if isLookingUp && pitch > hideEnterRad { layer.isHidden = true }
        }

        // If hidden, we’re done.
        if layer.isHidden { return }

        // 2) Depth-read gating (independent hysteresis, gentler thresholds).
        //    We read the state from an existing material to avoid extra storage.
        let readsNow: Bool = (anyMaterial?.readsFromDepthBuffer ?? true)

        let wantDepthOff = isLookingUp && pitch > depthOffEnter
        let wantDepthOn  = (!isLookingUp || pitch < depthOffExit)

        if wantDepthOff && readsNow {
            // Flip OFF readsFromDepthBuffer on all puff materials once.
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials { m.readsFromDepthBuffer = false }
            }
        } else if wantDepthOn && !readsNow {
            // Flip it back ON once we’re away from the zenith.
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials { m.readsFromDepthBuffer = true }
            }
        }
    }
}
