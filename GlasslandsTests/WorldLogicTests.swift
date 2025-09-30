//
//  WorldLogicTests.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import Foundation
@testable import Glasslands

#if canImport(Testing)
import Testing

@MainActor
struct WorldLogicTests {
    @Test
    func deterministicTilesForSameSeed() {
        let seed = "RAIN_FOX_PEAKS"

        let recipe = BiomeSynthesisService().recipe(for: seed)
        let ctx1 = WorldContext(recipe: recipe, tileSize: 40, chunkTiles: IVec2(16, 16))
        let ctx2 = WorldContext(recipe: recipe, tileSize: 40, chunkTiles: IVec2(16, 16))

        let c1 = TileClassifier(context: ctx1)
        let c2 = TileClassifier(context: ctx2)

        let coords = [IVec2(0, 0), IVec2(10, 20), IVec2(-15, 7), IVec2(123, -88)]
        for xy in coords {
            #expect(c1.tile(at: xy) == c2.tile(at: xy))
        }
    }
}

#else
import XCTest

@MainActor
final class WorldLogicTests_XCTest: XCTestCase {
    func testDeterministicTilesForSameSeed() {
        let seed = "RAIN_FOX_PEAKS"

        let recipe = BiomeSynthesisService().recipe(for: seed)
        let ctx1 = WorldContext(recipe: recipe, tileSize: 40, chunkTiles: IVec2(16, 16))
        let ctx2 = WorldContext(recipe: recipe, tileSize: 40, chunkTiles: IVec2(16, 16))

        let c1 = TileClassifier(context: ctx1)
        let c2 = TileClassifier(context: ctx2)

        let coords = [IVec2(0, 0), IVec2(10, 20), IVec2(-15, 7), IVec2(123, -88)]
        for xy in coords {
            XCTAssertEqual(c1.tile(at: xy), c2.tile(at: xy))
        }
    }
}
#endif
