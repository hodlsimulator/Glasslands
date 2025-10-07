//
//  CloudBillboardMaterial+Compat.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Keeps older call sites working by forwarding to the slab-half API.
//

import SceneKit
import simd

extension CloudBillboardMaterial {
    /// Historical entry point used by factories. Returns a volumetric impostor
    /// with a safe default world slab half-thickness. The real per-node value
    /// is set later by `enableVolumetricCloudImpostors(true)`.
    @MainActor
    static func makeCurrent() -> SCNMaterial {
        makeVolumetricImpostor(defaultSlabHalf: 0.6)
    }
}
