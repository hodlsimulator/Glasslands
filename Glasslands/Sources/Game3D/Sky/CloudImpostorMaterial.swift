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
        CloudImpostorProgram.makeMaterial(halfWidth: max(0.001, halfW),
                                          halfHeight: max(0.001, halfH))
    }
}
