//
//  FirstPersonEngine+ZenithCull.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//

import SceneKit
import simd

extension FirstPersonEngine {

    private enum ZenithCullState {
        static var wasLookingUp: Bool = false
    }

    @MainActor
    func updateZenithCull() {
        // No billboard layer -> nothing to cull.
        guard cloudLayerNode != nil else { return }

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let forwardW = simd_normalize(pov.simdWorldFront)

        // Looking up when camera forward points significantly towards +Y.
        let lookingUp = forwardW.y > 0.55

        if lookingUp == ZenithCullState.wasLookingUp {
            return
        }
        ZenithCullState.wasLookingUp = lookingUp

        let readsDepth = !lookingUp
        for n in cloudBillboardNodes {
            n.geometry?.firstMaterial?.readsFromDepthBuffer = readsDepth
        }
    }
}
