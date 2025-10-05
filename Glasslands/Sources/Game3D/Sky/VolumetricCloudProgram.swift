//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

// VolumetricCloudProgram.swift
// Glasslands

import SceneKit
import UIKit

enum VolumetricCloudProgram {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        // Forward to the shader-modifier implementation (no SCNProgram; render-thread safe).
        return VolumetricCloudMaterial.makeMaterial()
    }
}
