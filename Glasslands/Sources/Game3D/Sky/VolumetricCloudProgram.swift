//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  CNProgram wrapper for SkyVolumetricClouds.metal (gl_vapour_*).
//  Binder copies bytes from VolCloudUniformsStore into the buffer named "uCloudsGL".
//

// VolumetricCloudProgram.swift
// Glasslands
//
// Binder-free wrapper: delegate to the shader-modifier material.
// This removes render-queue closures entirely.

import SceneKit
import UIKit

enum VolumetricCloudProgram {
    static func makeMaterial() -> SCNMaterial {
        return VolumetricCloudMaterial.makeMaterial()
    }
}
