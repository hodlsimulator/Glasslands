//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  True volumetric vapour: base mass + micro "puff" cells.
//  RGB is premultiplied pure white; alpha carries shading.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        VolumetricCloudProgram.makeMaterial()
    }
}
