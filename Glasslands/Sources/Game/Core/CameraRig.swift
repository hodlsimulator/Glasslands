//
//  CameraRig.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

/// Simple smooth-follow rig that keeps the SKCameraNode gliding towards the target.
final class CameraRig: SKNode {
    private weak var cameraNode: SKCameraNode?
    private weak var target: SKNode?
    private var smoothing: CGFloat = 0.12

    func attach(camera: SKCameraNode, to target: SKNode, smoothing: CGFloat) {
        self.cameraNode = camera
        self.target = target
        self.smoothing = smoothing
        camera.position = target.position
    }

    func update() {
        guard let cam = cameraNode, let tgt = target else { return }
        let a = max(0, min(1, smoothing))
        cam.position = CGPoint(
            x: cam.position.x + (tgt.position.x - cam.position.x) * a,
            y: cam.position.y + (tgt.position.y - cam.position.y) * a
        )
    }
}
