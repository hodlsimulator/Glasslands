//
//  CollisionSystem.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import CoreGraphics

enum CollisionSystem {
    /// Simple, forgiving collision: only the centre tile must be walkable.
    /// (Much nicer feel for a first playable slice.)
    static func canOccupy(point p: CGPoint, classifier: TileClassifier) -> Bool {
        let ctx = classifier.context
        let t = classifier.tile(at: ctx.worldToTile(p))
        return !t.isBlocked
    }
}
