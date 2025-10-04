//
//  CloudBillboardTypes.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Simple internal types that describe a billboard cloud.
//

import simd

struct CloudPuffSpec {
    var pos: simd_float3
    var size: Float
    var roll: Float
    var atlasIndex: Int
    var opacity: Float            // 0..1 (premultiplied)
    var tint: simd_float3?        // optional multiply tint; nil = white
}

struct CloudClusterSpec {
    var puffs: [CloudPuffSpec]
}
