//
//  TouchInput.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

/// Simple virtual thumbstick:
/// - Anchor at first touch location in camera space
/// - Vector = current - anchor
/// - Dead-zone near centre
/// - Max radius clamps speed proportionally
final class TouchInput {
    private var isActive = false
    private var anchor = CGPoint.zero   // in camera space
    private var current = CGPoint.zero  // in camera space

    private let maxRadius: CGFloat = 80
    private let deadZone: CGFloat = 6

    func desiredVelocity(maxSpeed: CGFloat) -> CGPoint {
        guard isActive else { return .zero }
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let len = CGFloat(hypot(dx, dy))
        if len < deadZone { return .zero }

        let scale = min(1.0, len / maxRadius)
        let invLen = 1.0 / max(len, 0.0001)
        return CGPoint(x: dx * invLen * maxSpeed * scale,
                       y: dy * invLen * maxSpeed * scale)
    }

    func touchesBegan(_ touches: Set<UITouch>, in scene: SKScene) {
        guard let t = touches.first, let cam = scene.camera else { return }
        anchor = t.location(in: cam)
        current = anchor
        isActive = true
    }

    func touchesMoved(_ touches: Set<UITouch>, in scene: SKScene) {
        guard isActive, let t = touches.first, let cam = scene.camera else { return }
        current = t.location(in: cam)
    }

    func touchesEnded(_ touches: Set<UITouch>, in scene: SKScene) {
        isActive = false
        anchor = .zero
        current = .zero
    }
}
