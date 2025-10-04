//
//  CloudBillboardTypes.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Simple internal types that describe a billboard cloud.
//

import simd

/// One sprite within a cumulus cluster.
struct CloudPuffSpec {
    var pos: simd_float3     // world position
    var size: Float          // square sprite size in world units
    var roll: Float          // Z rotation in radians
    var atlasIndex: Int      // selects a sprite from the atlas
    var opacity: Float       // 0..1 (premultiplied)
}

/// One cluster composed of several overlapping puffs.
struct CloudClusterSpec {
    var puffs: [CloudPuffSpec]
}
