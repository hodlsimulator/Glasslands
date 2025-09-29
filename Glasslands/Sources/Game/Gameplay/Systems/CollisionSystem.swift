//
//  CollisionSystem.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import CoreGraphics

enum CollisionSystem {
    static func canOccupy(point p: CGPoint, classifier: TileClassifier) -> Bool {
        // Sample the centre tile & 3×3 neighbourhood for blocked tiles
        let ctx = classifier.context
        let tile = ctx.worldToTile(p)
        for dy in -1...1 {
            for dx in -1...1 {
                let t = classifier.tile(at: IVec2(tile.x + dx, tile.y + dy))
                if t.isBlocked { return false }
            }
        }
        return true
    }
}
