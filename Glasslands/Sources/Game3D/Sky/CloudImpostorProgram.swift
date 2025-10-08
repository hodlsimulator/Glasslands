//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Crash-safe impostor material: no SCNProgram, no shader modifiers.
//  Leaves sprites/tinting intact so billboards render without touching SceneKit's technique/program paths.
//

import SceneKit
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.shaderModifiers = nil
        m.program = nil
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
