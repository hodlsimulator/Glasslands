//
//  FirstPersonEngine+ZenithCull.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Pitch-aware guards for the billboard cloud layer that do NOT alter billboard
//  orientation (keeps .all for visuals). Near the zenith the system turns OFF
//  readsFromDepthBuffer (with hysteresis) to avoid tile-GPU stalls.
//

import SceneKit

extension FirstPersonEngine {

    /// Prevents tile-GPU stalls when the sky fills the screen.
    /// When looking steeply up, disable readsFromDepthBuffer on cloud puff materials.
    /// Uses hysteresis so it doesn't flicker when hovering around the threshold.
    ///
    /// - Parameters:
    ///   - depthOffEnter: pitch (radians) above which depth reads turn off (looking up).
    ///   - depthOffExit:  pitch (radians) below which depth reads turn back on.
    ///   - hideEnterRad:  retained for API stability; no longer used.
    ///   - hideExitRad:   retained for API stability; no longer used.
    @MainActor
    func updateZenithCull(
        depthOffEnter: Float = 1.05,
        depthOffExit: Float = 0.95,
        hideEnterRad: Float = 1.35,
        hideExitRad: Float = 1.20
    ) {
        guard let layer = scene.rootNode.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        // Ensure the layer is visible. The hide path was removed because it is
        // visually jarring (clouds popping off at the zenith).
        if layer.isHidden { layer.isHidden = false }

        // Retained for API stability; intentionally unused.
        _ = hideEnterRad
        _ = hideExitRad

        // Determine current readsFromDepthBuffer state from any puff material.
        var anyMaterial: SCNMaterial?
        if let g = layer.childNodes.first?.geometry { anyMaterial = g.firstMaterial }
        if anyMaterial == nil {
            // Walk down a bit: layer → group → puff.
            for g in layer.childNodes {
                if let puff = g.childNodes.first, let mat = puff.geometry?.firstMaterial {
                    anyMaterial = mat
                    break
                }
            }
        }

        let readsNow = anyMaterial?.readsFromDepthBuffer ?? true

        let isLookingUp = pitch > 0
        let wantDepthOff = isLookingUp && pitch > depthOffEnter
        let wantDepthOn = (!isLookingUp || pitch < depthOffExit)

        if wantDepthOff && readsNow {
            // Disable depth reads for all puff materials in the layer.
            for group in layer.childNodes {
                for puff in group.childNodes {
                    puff.geometry?.materials.forEach { $0.readsFromDepthBuffer = false }
                }
            }
        } else if wantDepthOn && !readsNow {
            // Re-enable depth reads.
            for group in layer.childNodes {
                for puff in group.childNodes {
                    puff.geometry?.materials.forEach { $0.readsFromDepthBuffer = true }
                }
            }
        }
    }
}
