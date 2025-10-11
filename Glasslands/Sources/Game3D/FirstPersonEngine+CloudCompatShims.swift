//
//  FirstPersonEngine+CloudCompatShims.swift
//  Glasslands
//
//  Created by . . on 10/12/25.
//

import SceneKit
import QuartzCore
import CoreGraphics

@MainActor
extension FirstPersonEngine {
    // Current pipeline may install clouds elsewhere; keep this as a safe no-op.
    func installVolumetricCloudsIfMissing() { }

    // Legacy call-site wants baseY/topY/coverage. Map to no-arg variant for now.
    func installVolumetricCloudsIfMissing(baseY: Float, topY: Float, coverage: Float) {
        installVolumetricCloudsIfMissing()
    }
    func installVolumetricCloudsIfMissing(baseY: CGFloat, topY: CGFloat, coverage: CGFloat) {
        installVolumetricCloudsIfMissing()
    }

    // Legacy tick without parameters → drive with current render time.
    func tickVolumetricClouds() {
        tickVolumetricClouds(atRenderTime: CACurrentMediaTime())
    }

    // If the engine doesn’t define this symbol in the current tree, keep it as a no-op.
    // When the real per-frame cloud advance exists, this will be shadowed by that definition.
    func tickVolumetricClouds(atRenderTime: CFTimeInterval) { }
}
