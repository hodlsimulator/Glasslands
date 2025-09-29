//
//  TouchInput.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

final class TouchInput {
    private var currentVector = CGPoint.zero

    func desiredVelocity(maxSpeed: CGFloat) -> CGPoint {
        let len = max(0.0001, hypot(currentVector.x, currentVector.y))
        let dir = CGPoint(x: currentVector.x / len, y: currentVector.y / len)
        return CGPoint(x: dir.x * maxSpeed, y: dir.y * maxSpeed)
    }

    func touchesBegan(_ touches: Set<UITouch>, in scene: SKScene) {
        updateVector(with: touches, in: scene)
    }
    func touchesMoved(_ touches: Set<UITouch>, in scene: SKScene) {
        updateVector(with: touches, in: scene)
    }
    func touchesEnded(_ touches: Set<UITouch>, in scene: SKScene) {
        currentVector = .zero
    }

    private func updateVector(with touches: Set<UITouch>, in scene: SKScene) {
        guard let t = touches.first, let camera = scene.camera else { return }
        let loc = t.location(in: camera)
        currentVector = loc // move towards finger relative to screen-centre
    }
}
