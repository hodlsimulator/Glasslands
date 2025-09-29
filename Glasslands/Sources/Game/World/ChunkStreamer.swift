//
//  ChunkStreamer.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit

struct ChunkRef: Hashable {
    let origin: IVec2 // in tiles
}

final class ChunkStreamer {
    private let ctx: WorldContext
    private weak var parent: SKNode?
    private var loaded: [ChunkRef: SKNode] = [:]

    var loadedChunkCount: Int { loaded.count }

    init(context: WorldContext, parent: SKNode) {
        self.ctx = context
        self.parent = parent
    }

    private func chunkIndex(for tile: IVec2) -> IVec2 {
        let cw = ctx.chunkTiles.x
        let ch = ctx.chunkTiles.y
        let cx = tile.x >= 0 ? tile.x / cw : ((tile.x + 1) / cw - 1)
        let cy = tile.y >= 0 ? tile.y / ch : ((tile.y + 1) / ch - 1)
        return IVec2(cx, cy)
    }

    private func chunkOrigin(_ ci: IVec2) -> IVec2 {
        IVec2(ci.x * ctx.chunkTiles.x, ci.y * ctx.chunkTiles.y)
    }

    func buildAround(_ pos: CGPoint, preloadRadius: Int, onChunkReady: ((ChunkRef) -> Void)? = nil) {
        let centerTile = ctx.worldToTile(pos)
        let centerIndex = chunkIndex(for: centerTile)
        for dy in -preloadRadius...preloadRadius {
            for dx in -preloadRadius...preloadRadius {
                let idx = IVec2(centerIndex.x + dx, centerIndex.y + dy)
                let ref = ChunkRef(origin: chunkOrigin(idx))
                if loaded[ref] == nil { buildChunk(ref, onChunkReady) }
            }
        }
    }

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
            node.removeFromParent()
            loaded.removeValue(forKey: ref)
        }
    }

    private func buildChunk(_ ref: ChunkRef, _ onReady: ((ChunkRef) -> Void)?) {
        guard let parent = parent else { return }
        let node = SKNode()
        node.name = "chunk_\(ref.origin.x)_\(ref.origin.y)"
        node.position = ctx.tileToWorld(ref.origin) - CGPoint(x: ctx.tileSize/2, y: ctx.tileSize/2)

        let classifier = TileClassifier(context: ctx)
        for ty in 0..<ctx.chunkTiles.y {
            for tx in 0..<ctx.chunkTiles.x {
                let tile = IVec2(ref.origin.x + tx, ref.origin.y + ty)
                let ttype = classifier.tile(at: tile)
                let color = classifier.color(for: ttype)
                let rect = CGRect(x: CGFloat(tx) * ctx.tileSize,
                                  y: CGFloat(ty) * ctx.tileSize,
                                  width: ctx.tileSize, height: ctx.tileSize)
                let sprite = SKSpriteNode(color: color, size: rect.size)
                sprite.anchorPoint = .zero
                sprite.position = rect.origin
                sprite.name = "tile_\(tile.x)_\(tile.y)"
                node.addChild(sprite)
            }
        }
        parent.addChild(node)
        loaded[ref] = node
        onReady?(ref)
    }
}
