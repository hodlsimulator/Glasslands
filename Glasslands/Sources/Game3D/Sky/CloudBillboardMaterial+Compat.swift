//
//  CloudBillboardMaterial+Compat.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Compatibility layer so older call sites using
//  CloudBillboardMaterial.makeCurrent() keep working.
//

import SceneKit
import UIKit

extension CloudBillboardMaterial {
    @MainActor
    static func makeCurrent() -> SCNMaterial {
        // Route to the current implementation used in our project.
        return makeVolumetricImpostor()
    }
}
