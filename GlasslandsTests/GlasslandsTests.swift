//
//  GlasslandsTests.swift
//  GlasslandsTests
//
//  Created by . . on 9/29/25.
//
// Marked @MainActor; uses the exposed Config.tilesX/tilesZ to avoid IVec2 internals.
//

import Testing
@testable import Glasslands
import SceneKit
import GameplayKit

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
        let coords: [(Double, Double)] = [(0,0), (10,20), (-15,7), (123,-88), (512.5, -1024.25)]
        for (x,y) in coords {
            #expect( abs(n1.sampleHeight(x, y) - n2.sampleHeight(x, y)) < 1e-9 )
            #expect( abs(n1.sampleMoisture(x, y) - n2.sampleMoisture(x, y)) < 1e-9 )
        }
    }

    @Test
    func terrainChunkVertexAndTriangleCounts() {
        let cfg = FirstPersonEngine.Config()
        let recipe = BiomeSynthesisService().recipe(for: "TEST_MESA_MIST")
        let noise = NoiseFields(recipe: recipe)

        let node = TerrainChunk3D.makeNode(originChunk: IVec2(0,0), cfg: cfg, noise: noise, recipe: recipe)
        #expect(node.geometry != nil)
        guard let g = node.geometry else { return }

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let expectedVerts = (tilesX + 1) * (tilesZ + 1)
        let expectedTris  = tilesX * tilesZ * 2

        let vCount = g.sources(for: SCNGeometrySource.Semantic.vertex).first?.vectorCount ?? -1
        let nCount = g.sources(for: SCNGeometrySource.Semantic.normal).first?.vectorCount ?? -1
        let cCount = g.sources(for: SCNGeometrySource.Semantic.color).first?.vectorCount ?? -1
        #expect(vCount == expectedVerts)
        #expect(nCount == expectedVerts)
        #expect(cCount == expectedVerts)

        if let e = g.elements.first {
            #expect(e.primitiveType == SCNGeometryPrimitiveType.triangles)
            #expect(e.primitiveCount == expectedTris)
        } else {
            Issue.record("Missing geometry element")
        }
    }
}
