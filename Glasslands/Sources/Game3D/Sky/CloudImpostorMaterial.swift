//
//  CloudImpostorMaterial.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//
//  Thin shim that delegates to the volumetric impostor shader-modifier material.
//

import SceneKit
import UIKit

enum CloudImpostorMaterial {
    @MainActor
    static func make(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
        // Use the original Metal-backed material. Half sizes are not needed here:
        // the engine pushes correct uniforms later.
        CloudBillboardMaterial.makeCurrent()
    }
}
