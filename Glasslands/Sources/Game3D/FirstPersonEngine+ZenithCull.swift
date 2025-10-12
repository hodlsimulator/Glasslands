//
//  FirstPersonEngine+ZenithCull.swift
//  Glasslands
//
//  Created by . . on 10/12/25.
//
//  Cull billboard clouds when looking near straight up to avoid GPU stalls.
//  Hysteresis avoids rapid flicker when hovering around the threshold.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    /// Hide/show the billboard cloud layer near zenith to prevent GPU stalls when the sky fills the screen.
    /// Enter/exit thresholds are in radians (π/2 = 1.5708). Defaults: enter at ~70°, exit at ~60°.
    @MainActor
    func updateZenithCull(enterRad: Float = 1.22, exitRad: Float = 1.05) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        // We only care about looking UP: pitch approaches +π/2 at the zenith.
        let isLookingUp = pitch > 0

        // Use the node's hidden state as our latch for hysteresis; no extra stored vars required.
        let wasHidden = layer.isHidden

        if wasHidden {
            // Exit hysteresis: once we pull back under the lower threshold, restore clouds.
            if isLookingUp == false || pitch < exitRad {
                layer.isHidden = false
            }
        } else {
            // Enter hysteresis: only hide clouds when we cross the upper threshold.
            if isLookingUp && pitch > enterRad {
                layer.isHidden = true
            }
        }
    }
}
