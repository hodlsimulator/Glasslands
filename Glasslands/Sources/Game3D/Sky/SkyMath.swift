//
//  SkyMath.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Small math/utility helpers shared by sky modules.
//

import Foundation
import simd

enum SkyMath {
    @inline(__always) static func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        x.isFinite ? min(hi, max(lo, x)) : lo
    }
    @inline(__always) static func smooth01(_ x: Float) -> Float {
        let t = clampf(x, 0, 1)
        return t * t * (3 - 2 * t)
    }
    @inline(__always) static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let d = e1 - e0
        return d == 0 ? (x < e0 ? 0 : 1) : smooth01((x - e0) / d)
    }
    @inline(__always) static func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 {
        a + (b - a) * t
    }
    @inline(__always) static func toByte(_ f: Float) -> UInt8 {
        UInt8(clampf(f, 0, 1) * 255.0 + 0.5)
    }
    @inline(__always) static func safeFloorInt(_ x: Float) -> Int {
        guard x.isFinite else { return 0 }
        let y = floorf(x)
        if y >= Float(Int.max) { return Int.max }
        if y <= Float(Int.min) { return Int.min }
        return Int(y)
    }
    @inline(__always) static func safeIndex(_ i: Int, _ lo: Int, _ hi: Int) -> Int {
        (i < lo) ? lo : (i > hi ? hi : i)
    }
    /// Tiny integer hash (useful for dithering).
    @inline(__always) static func h2(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
        var h = UInt32(bitPattern: x) &* 374_761_393
        h &+= UInt32(bitPattern: y) &* 668_265_263
        h &+= s &* 2_246_822_519 &+ 0x9E37_79B9
        h ^= h >> 13
        h &*= 1_274_126_177
        return h
    }
}
