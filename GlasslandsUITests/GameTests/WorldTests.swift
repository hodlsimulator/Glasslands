//
//  WorldTests.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import XCTest
@testable import Glasslands

final class WorldTests: XCTestCase {
    func testDeterministicTilesForSameSeed() {
        let seed = "RAIN_FOX_PEAKS"
        let service = BiomeSynthesisService()
        let r1 = service.recipe(for: seed)
        let r2 = service.recipe(for: seed)
        XCTAssertEqual(r1, r2)

        let ctx1 = WorldContext(recipe: r1, tileSize: 40, chunkTiles: IVec2(16,16))
        let ctx2 = WorldContext(recipe: r2, tileSize: 40, chunkTiles: IVec2(16,16))
        let c1 = TileClassifier(context: ctx1)
        let c2 = TileClassifier(context: ctx2)

        let coords = [IVec2(0,0), IVec2(10,20), IVec2(-15,7), IVec2(123,-88)]
        for xy in coords {
            XCTAssertEqual(c1.tile(at: xy), c2.tile(at: xy))
        }
    }
}
