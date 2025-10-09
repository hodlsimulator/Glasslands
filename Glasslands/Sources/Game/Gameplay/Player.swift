//
//  Player.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

final class PlayerNode: SKShapeNode {
    init(radius: CGFloat) {
        super.init()

        let c = SKShapeNode(circleOfRadius: radius)
        c.fillColor = .systemOrange
        c.strokeColor = .black
        c.lineWidth = 2
        c.zPosition = 20
        addChild(c)

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.isDynamic = true
        body.affectedByGravity = false
        body.allowsRotation = false
        self.physicsBody = body

        // No SpriteKit lighting/shadows here (SKShapeNode doesn't support those).
        // Make sure there’s no soft “fake” shadow via glow.
        self.glowWidth = 0
        c.glowWidth = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
