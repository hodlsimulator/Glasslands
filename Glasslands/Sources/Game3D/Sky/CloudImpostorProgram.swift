//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Back-compat shim that delegates to the shader-modifier material.
//  No SCNProgram buffer binders; uniforms are plain #pragma arguments.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial(halfSize: simd_float2) -> SCNMaterial {
        CloudImpostorMaterial.make(
            halfW: CGFloat(max(0.001, halfSize.x)),
            halfH: CGFloat(max(0.001, halfSize.y))
        )
    }

    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        CloudImpostorMaterial.make(halfW: max(0.001, halfWidth), halfH: max(0.001, halfHeight))
    }

    static func makeMaterial() -> SCNMaterial {
        CloudImpostorMaterial.make(halfW: 0.5, halfH: 0.5)
    }
}
