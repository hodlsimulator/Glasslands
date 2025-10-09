//
//  FirstPersonEngine+Cooler.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//

import SceneKit
import QuartzCore
import UIKit

extension FirstPersonEngine {
    /// Apply cooler defaults to the SCNView/CAMetalLayer once attached.
    @MainActor
    func applyCoolerSurfaceDefaults() {
        guard let v = scnView, let layer = v.layer as? CAMetalLayer else { return }
        layer.isOpaque = true
        layer.wantsExtendedDynamicRangeContent = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.maximumDrawableCount = 2

        // Cap sensibly: 40 fps on 120 Hz screens; 30 otherwise.
        let mfps = v.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        v.preferredFramesPerSecond = (mfps >= 120) ? 40 : 30
        v.rendersContinuously = true
        v.isPlaying = true
    }
}
