//
//  BeaconStructures.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit
import GameplayKit

final class BeaconStructures {
    private let ctx: WorldContext
    private let classifier: TileClassifier
    private let rng: GKMersenneTwisterRandomSource

    init(context: WorldContext) {
        self.ctx = context
        self.classifier = TileClassifier(context: context)
        self.rng = GKMersenneTwisterRandomSource(seed: UInt64(context.recipe.seed64))
    }

    func placeBeacons(in chunk: ChunkRef, into parent: SKNode, categoryMask: UInt32) {
        // Density based on recipe setpieces
        let rarity = ctx.recipe.setpieces.first(where: { $0.name == "glass_beacon" })?.rarity ?? 0.015
        let tilesPerChunk = ctx.chunkTiles.x * ctx.chunkTiles.y
        let expected = Int(round(Double(tilesPerChunk) * rarity))

        var placed = 0
        var attempts = 0
        while placed < expected && attempts < tilesPerChunk * 2 {
            attempts += 1
            let tx = chunk.origin.x + rng.nextInt(upperBound: ctx.chunkTiles.x)
            let ty = chunk.origin.y + rng.nextInt(upperBound: ctx.chunkTiles.y)
            let tile = IVec2(tx, ty)
            let ttype = classifier.tile(at: tile)

            guard ttype == .grass || ttype == .forest || ttype == .sand else { continue }

            let p = ctx.tileToWorld(tile)
            let node = SKShapeNode(circleOfRadius: ctx.tileSize * 0.35)
            node.fillColor = .white.withAlphaComponent(0.6)
            node.strokeColor = .clear
            node.position = p
            node.zPosition = 10
            node.name = "beacon"

            // shimmer
            let pulseUp = SKAction.scale(to: 1.06, duration: 0.8)
            pulseUp.timingMode = .easeInEaseOut
            node.run(.repeatForever(.sequence([pulseUp, pulseUp.reversed()])))

            // Physics for pickup
            let body = SKPhysicsBody(circleOfRadius: ctx.tileSize * 0.35)
            body.isDynamic = false
            body.categoryBitMask = categoryMask
            body.contactTestBitMask = 0
            body.collisionBitMask = 0
            node.physicsBody = body

            parent.addChild(node)
            placed += 1
        }
    }
}
