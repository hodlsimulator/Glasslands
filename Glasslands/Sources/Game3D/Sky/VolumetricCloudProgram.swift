//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  CNProgram wrapper for SkyVolumetricClouds.metal (gl_vapour_*).
//  Binder copies bytes from VolCloudUniformsStore into the buffer named "uCloudsGL".
//
//  Shim that delegates the sky dome material to the SkyAtmosphereMaterial.
//  Keeps the cloud dome path binder-free.
//

import SceneKit
import UIKit

enum VolumetricCloudProgram {
    static func makeMaterial() -> SCNMaterial {
        SkyAtmosphereMaterial.make()
    }
}
