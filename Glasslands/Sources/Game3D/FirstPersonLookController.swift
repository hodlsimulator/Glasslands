//
//  FirstPersonLookController.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import Foundation
import SceneKit
import simd

struct FirstPersonLookController {
    private(set) var yaw: Float = 0      // +Y radians
    private(set) var pitch: Float = 0    // +X radians
    var sensitivity: Float               // radians per UIKit point
    var maxPitch: Float                  // clamp magnitude

    init(sensitivity: Float, maxPitch: Float) {
        self.sensitivity = max(0.0001, sensitivity)
        self.maxPitch = max(0.1, maxPitch)
    }

    mutating func applyDelta(points: SIMD2<Float>) {
        // Swipe right -> turn right
        yaw   -= points.x * sensitivity
        // Thumb up (dy < 0) -> look up
        pitch -= points.y * sensitivity

        let m = maxPitch
        if pitch >  m { pitch =  m }
        if pitch < -m { pitch = -m }
    }

    func apply(to playerNode: SCNNode, pitchNode: SCNNode) {
        playerNode.eulerAngles.y = yaw
        pitchNode.eulerAngles.x  = pitch
    }
}
