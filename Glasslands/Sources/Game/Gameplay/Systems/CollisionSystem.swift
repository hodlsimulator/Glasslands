//
//  CollisionSystem.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import CoreGraphics

enum CollisionSystem {
    static func canOccupy(point p: CGPoint, classifier: TileClassifier) -> Bool {
        // Sample the center tile & 3x3 neighborhood for blocked tiles
        let ctx = classifier.value(forKey: "ctx") as? WorldContext ?? {
            // Reflective access fallback: the classifier keeps context in a private property;
            // we add a tiny helper to expose it safely.
            return classifierContext(classifier)
        }()
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

// Small helper to access context (since TileClassifier keeps it private)
fileprivate func classifierContext(_ classifier: TileClassifier) -> WorldContext {
    // Unsafe but fine: reconstruct via mirror
    let m = Mirror(reflecting: classifier)
    for c in m.children {
        if let ctx = c.value as? WorldContext { return ctx }
    }
    fatalError("WorldContext not found on TileClassifier")
}
