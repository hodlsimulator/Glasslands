//
//  ChunkStreamer.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

/// Reference to a chunk anchored at a **tile-space** origin.
struct ChunkRef: Hashable {
    let origin: IVec2 // in tiles
}

/// Streams 2D tile chunks around a centre point, creating/removing SKNodes per chunk.
final class ChunkStreamer {
    private let ctx: WorldContext
    private weak var parent: SKNode?
    private var loaded: [ChunkRef: SKNode] = [:]

    var loadedChunkCount: Int { loaded.count }

    init(context: WorldContext, parent: SKNode) {
        self.ctx = context
        self.parent = parent
    }

    // MARK: - Indexing

    private func chunkIndex(for tile: IVec2) -> IVec2 {
        // Integer floor-division that behaves nicely for negatives.
        let cw = ctx.chunkTiles.x
        let ch = ctx.chunkTiles.y

        let cx = tile.x >= 0 ? tile.x / cw : ((tile.x + 1) / cw - 1)
        let cy = tile.y >= 0 ? tile.y / ch : ((tile.y + 1) / ch - 1)
        return IVec2(cx, cy)
    }

    private func chunkOrigin(_ ci: IVec2) -> IVec2 {
        IVec2(ci.x * ctx.chunkTiles.x, ci.y * ctx.chunkTiles.y)
    }

    // MARK: - Lifecycle

    /// Preload a square of chunks around a world position.
    func buildAround(_ pos: CGPoint, preloadRadius: Int, onChunkReady: ((ChunkRef) -> Void)? = nil) {
        let centerTile = ctx.worldToTile(pos)
        let centerIndex = chunkIndex(for: centerTile)

        for dy in -preloadRadius...preloadRadius {
            for dx in -preloadRadius...preloadRadius {
                let idx = IVec2(centerIndex.x + dx, centerIndex.y + dy)
                let ref = ChunkRef(origin: chunkOrigin(idx))
                if loaded[ref] == nil {
                    buildChunk(ref, onChunkReady)
                }
            }
        }
    }

    /// Keep a (2*margin+1)×(2*margin+1) window of chunks alive centred on `center`.
    func updateVisible(center: CGPoint, marginChunks: Int, onChunkReady: ((ChunkRef) -> Void)? = nil) {
        let centerTile = ctx.worldToTile(center)
        let centerIdx = chunkIndex(for: centerTile)

        var keep: Set<ChunkRef> = []

        for dy in -marginChunks...marginChunks {
            for dx in -marginChunks...marginChunks {
                let idx = IVec2(centerIdx.x + dx, centerIdx.y + dy)
                let ref = ChunkRef(origin: chunkOrigin(idx))
                keep.insert(ref)
                if loaded[ref] == nil {
                    buildChunk(ref, onChunkReady)
                }
            }
        }

        // Unload distant chunks
        for (ref, node) in loaded where !keep.contains(ref) {
            node.removeAllActions()
            node.removeAllChildren()
            node.removeFromParent()
            loaded.removeValue(forKey: ref)
        }
    }

    // MARK: - Building

    /// Build a chunk node at `ref`, filled with coloured tiles.
    private func buildChunk(_ ref: ChunkRef, _ onReady: ((ChunkRef) -> Void)?) {
        guard let parent = parent else { return }

        // Position the chunk so its local (0,0) is the top-left of the first tile.
        let node = SKNode()
        node.name = "chunk_\(ref.origin.x)_\(ref.origin.y)"
        node.zPosition = 0

        // World centre of the first tile, then subtract half-tile to get its top-left
        node.position = ctx.tileToWorld(ref.origin) - CGPoint(x: ctx.tileSize / 2, y: ctx.tileSize / 2)

        // Fill the chunk with sprites (one per tile). This is fine for a slice.
        let classifier = TileClassifier(context: ctx)
        let tileSize = ctx.tileSize
        let chunkW = ctx.chunkTiles.x
        let chunkH = ctx.chunkTiles.y

        // Optionally batch draw order for small overdraw wins
        let baseZ: CGFloat = 0

        for ty in 0..<chunkH {
            for tx in 0..<chunkW {
                let tile = IVec2(ref.origin.x + tx, ref.origin.y + ty)
                let ttype = classifier.tile(at: tile)
                let colour = classifier.color(for: ttype)

                let sprite = SKSpriteNode(color: colour, size: CGSize(width: tileSize, height: tileSize))
                sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                sprite.position = CGPoint(
                    x: CGFloat(tx) * tileSize + tileSize / 2,
                    y: CGFloat(ty) * tileSize + tileSize / 2
                )
                sprite.zPosition = baseZ

                // Subtle shading for blocked tiles to help readability
                if ttype.isBlocked {
                    sprite.colorBlendFactor = 0.15
                }

                node.addChild(sprite)
            }
        }

        parent.addChild(node)
        loaded[ref] = node
        onReady?(ref)
    }
}
