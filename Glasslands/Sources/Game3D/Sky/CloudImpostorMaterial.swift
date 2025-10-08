//
//  CloudImpostorMaterial.swift
//  Glasslands
//
//  Created by . . on 10/8/25.
//
//  Volumetric vapour impostors via a SceneKit fragment shader modifier.
//  Helpers live in #pragma declarations (top-level); only statements in #pragma body.
//  Vapour sampling is anchored to the impostor’s model origin so the cloud moves as a unit.
//

import SceneKit
import UIKit
import simd

enum CloudImpostorMaterial {
    @MainActor
    static func make(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
        // uHalfSize is provided by the per-node binder in CloudImpostorProgram.
        CloudImpostorProgram.makeMaterial()
    }
}
