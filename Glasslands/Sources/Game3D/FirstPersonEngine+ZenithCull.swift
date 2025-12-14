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
        // Depth reads for clouds are forced OFF (see applyCloudSunUniforms()).
        // Leaving this as a no-op prevents iOS tile resolve stalls and avoids pitch-dependent flicker.
        return
    }
}
