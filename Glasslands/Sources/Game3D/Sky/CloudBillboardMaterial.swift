//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Routes billboards to the volumetric impostor (true vapour).
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {
    // Used by your diagnostics to verify materials were swapped
    static let volumetricMarker = "/* VOL_IMPOSTOR_VAPOUR */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        // Route billboards to the volumetric SCNProgram (true vapour).
        return CloudImpostorProgram.makeMaterial()
    }

    // Kept in case you ever want to A/B
    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        return m
    }
}
