//
//  GlasslandsTests.swift
//  GlasslandsTests
//
//  Created by . . on 9/29/25.
//
// Marked @MainActor; uses the exposed Config.tilesX/tilesZ to avoid IVec2 internals.
//

import SceneKit
import GameplayKit
@testable import Glasslands

#if canImport(Testing)
import Testing

@MainActor
struct GlasslandsTests {
    @Test
    func noiseIsDeterministicForSeed() {
        let seed = "RAIN_FOX_PEAKS"
        let svc = BiomeSynthesisService()
        let r1 = svc.recipe(for: seed)
        let r2 = svc.recipe(for: seed)
        #expect(r1 == r2)

        let n1 = NoiseFields(recipe: r1)
        let n2 = NoiseFields(recipe: r2)

        let coords: [(Double, Double)] = [
            (0, 0), (10, 20), (-15, 7), (123, -88), (512.5, -1024.25)
        ]
        for (x, y) in coords {
            #expect(abs(n1.sampleHeight(x, y)   - n2.sampleHeight(x, y))   < 1e-9)
            #expect(abs(n1.sampleMoisture(x, y) - n2.sampleMoisture(x, y)) < 1e-9)
        }
    }

    @Test
    func terrainChunkVertexAndTriangleCounts() {
        let cfg = FirstPersonEngine.Config()
        let recipe = BiomeSynthesisService().recipe(for: "TEST_MESA_MIST")
        let noise = NoiseFields(recipe: recipe)

        // NOTE: TerrainChunk3D is nested under FirstPersonEngine.
        let node = FirstPersonEngine.TerrainChunk3D.makeNode(
            originChunk: IVec2(0, 0),
            cfg: cfg,
            noise: noise,
            recipe: recipe
        )

        #expect(node.geometry != nil)
        guard let g = node.geometry else { return }

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let expectedVerts = (tilesX + 1) * (tilesZ + 1)
        let expectedTris  = tilesX * tilesZ * 2

        let vCount = g.sources(for: .vertex).first?.vectorCount ?? -1
        let nCount = g.sources(for: .normal).first?.vectorCount ?? -1
        let cCount = g.sources(for: .color).first?.vectorCount ?? -1

        #expect(vCount == expectedVerts)
        #expect(nCount == expectedVerts)
        #expect(cCount == expectedVerts)

        if let e = g.elements.first {
            #expect(e.primitiveType == .triangles)
            #expect(e.primitiveCount == expectedTris)
        } else {
            Issue.record("Missing geometry element")
        }
    }
}

#else
import XCTest

@MainActor
final class GlasslandsTests_XCTest: XCTestCase {
    func testNoiseIsDeterministicForSeed() {
        let seed = "RAIN_FOX_PEAKS"
        let svc = BiomeSynthesisService()
        let r1 = svc.recipe(for: seed)
        let r2 = svc.recipe(for: seed)
        XCTAssertEqual(r1, r2)

        let n1 = NoiseFields(recipe: r1)
        let n2 = NoiseFields(recipe: r2)

        let coords: [(Double, Double)] = [
            (0, 0), (10, 20), (-15, 7), (123, -88), (512.5, -1024.25)
        ]
        for (x, y) in coords {
            XCTAssertLessThan(abs(n1.sampleHeight(x, y)   - n2.sampleHeight(x, y)), 1e-9)
            XCTAssertLessThan(abs(n1.sampleMoisture(x, y) - n2.sampleMoisture(x, y)), 1e-9)
        }
    }

    func testTerrainChunkVertexAndTriangleCounts() {
        let cfg = FirstPersonEngine.Config()
        let recipe = BiomeSynthesisService().recipe(for: "TEST_MESA_MIST")
        let noise = NoiseFields(recipe: recipe)

        // NOTE: TerrainChunk3D is nested under FirstPersonEngine.
        let node = FirstPersonEngine.TerrainChunk3D.makeNode(
            originChunk: IVec2(0, 0),
            cfg: cfg,
            noise: noise,
            recipe: recipe
        )

        XCTAssertNotNil(node.geometry)
        guard let g = node.geometry else { return }

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let expectedVerts = (tilesX + 1) * (tilesZ + 1)
        let expectedTris  = tilesX * tilesZ * 2

        let vCount = g.sources(for: .vertex).first?.vectorCount ?? -1
        let nCount = g.sources(for: .normal).first?.vectorCount ?? -1
        let cCount = g.sources(for: .color).first?.vectorCount ?? -1

        XCTAssertEqual(vCount, expectedVerts)
        XCTAssertEqual(nCount, expectedVerts)
        XCTAssertEqual(cCount, expectedVerts)

        if let e = g.elements.first {
            XCTAssertEqual(e.primitiveType, .triangles)
            XCTAssertEqual(e.primitiveCount, expectedTris)
        } else {
            XCTFail("Missing geometry element")
        }
    }
}
#endif
