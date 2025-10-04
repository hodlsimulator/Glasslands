//
//  SceneKitHelpers+Grass.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Procedural, tileable grass textures (albedo, normal, macro). Cached on first use.
//  Kept tiny (<=512²) and repeated per-tile for zero runtime cost.
//

import UIKit
import GameplayKit
import CoreGraphics
import simd

extension SceneKitHelpers {

    // Repeat policy: integer repeats per chunk to avoid seams between chunks.
    // With tileSize=16 and 64 tiles/side, a "repeat 4× per tile" => 256× per chunk (integer).
    static let grassRepeatsPerTile: CGFloat = 4.0
    static let grassMacroRepeatsAcrossChunk: CGFloat = 8.0

    private static var _grassAlbedo: UIImage?
    private static var _grassNormal: UIImage?
    private static var _grassMacro: UIImage?

    static func grassAlbedoTexture(size: Int = 512) -> UIImage {
        if let img = _grassAlbedo { return img }
        let img = grassAlbedoImage(size: size)
        _grassAlbedo = img
        return img
    }

    static func grassNormalTexture(size: Int = 512, strength: Double = 1.6) -> UIImage {
        if let img = _grassNormal { return img }
        let img = grassNormalImage(size: size, strength: strength)
        _grassNormal = img
        return img
    }

    static func grassMacroVariationTexture(size: Int = 256) -> UIImage {
        if let img = _grassMacro { return img }
        let img = grassMacroImage(size: size)
        _grassMacro = img
        return img
    }
}

// MARK: - Private generation

private extension SceneKitHelpers {

    // Subtle green with micro-variation and occasional straw flecks; seamless.
    static func grassAlbedoImage(size: Int) -> UIImage {
        let W = max(64, size), H = max(64, size)

        let seedBase: Int32 = 0x4A10_BA5E
        let grain = GKNoise(GKPerlinNoiseSource(frequency: 6.0, octaveCount: 4, persistence: 0.52, lacunarity: 2.1, seed: seedBase))
        let lumps = GKNoise(GKBillowNoiseSource(frequency: 1.2, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seedBase &+ 101))
        let speck = GKNoise(GKRidgedNoiseSource(frequency: 8.0, octaveCount: 2, lacunarity: 2.0, seed: seedBase &+ 202))

        let grainMap = GKNoiseMap(grain,
                                  size: vector_double2(1, 1),
                                  origin: vector_double2(0, 0),
                                  sampleCount: vector_int2(Int32(W), Int32(H)),
                                  seamless: true)
        let lumpsMap = GKNoiseMap(lumps, size: vector_double2(1, 1), origin: vector_double2(0, 0),
                                  sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)
        let speckMap = GKNoiseMap(speck, size: vector_double2(1, 1), origin: vector_double2(0, 0),
                                  sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)

        var px = [UInt8](repeating: 0, count: W * H * 4)
        let base = SIMD3<Double>(0.32, 0.62, 0.34)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                func n01(_ v: Double) -> Double { v * 0.5 + 0.5 }

                let g = n01(Double(grainMap.value(at: vector_int2(Int32(x), Int32(y)))))
                let l = n01(Double(lumpsMap.value(at: vector_int2(Int32(x), Int32(y)))))
                let s = max(0.0, 1.0 - n01(Double(speckMap.value(at: vector_int2(Int32(x), Int32(y))))) * 1.2)

                let tint = 0.88 + 0.18 * g + 0.10 * (l - 0.5)
                var col = base * tint
                if s > 1.05 {
                    col = mix(col, SIMD3<Double>(0.50, 0.45, 0.28), 0.25)
                }

                px[i + 0] = toU8(clamp(col.x, lower: 0.0, upper: 1.0))
                px[i + 1] = toU8(clamp(col.y, lower: 0.0, upper: 1.0))
                px[i + 2] = toU8(clamp(col.z, lower: 0.0, upper: 1.0))
                px[i + 3] = 255
            }
        }
        return imageFromRGBA(px: &px, width: W, height: H)
    }

    // Normal from a small seamless heightfield; strength in world-normal space.
    static func grassNormalImage(size: Int, strength: Double) -> UIImage {
        let W = max(64, size), H = max(64, size)

        // 0x9E37_79B9 as signed Int32
        let seed: Int32 = -1640531527
        let hNoise = GKNoise(GKPerlinNoiseSource(frequency: 5.0, octaveCount: 4, persistence: 0.52, lacunarity: 2.0, seed: seed))
        let hMap = GKNoiseMap(hNoise, size: vector_double2(1, 1), origin: vector_double2(0, 0),
                              sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)

        func h(_ x: Int, _ y: Int) -> Double {
            let xx = (x % W + W) % W
            let yy = (y % H + H) % H
            let v = Double(hMap.value(at: vector_int2(Int32(xx), Int32(yy))))
            return v * 0.5 + 0.5
        }

        var px = [UInt8](repeating: 0, count: W * H * 4)
        let k = max(0.001, strength)
        for y in 0..<H {
            for x in 0..<W {
                let dx = h(x+1, y) - h(x-1, y)
                let dy = h(x, y+1) - h(x, y-1)
                var N = SIMD3<Double>(-dx * k, 1.0, -dy * k)
                N = normalize(N)

                let nx = toU8(clamp((N.x * 0.5) + 0.5, lower: 0.0, upper: 1.0))
                let ny = toU8(clamp((N.y * 0.5) + 0.5, lower: 0.0, upper: 1.0))
                let nz = toU8(clamp((N.z * 0.5) + 0.5, lower: 0.0, upper: 1.0))

                let i = (y * W + x) * 4
                px[i + 0] = nx
                px[i + 1] = ny
                px[i + 2] = nz
                px[i + 3] = 255
            }
        }
        return imageFromRGBA(px: &px, width: W, height: H)
    }

    // Gentle large-scale brightness modulation to break repetition (used as material.multiply).
    static func grassMacroImage(size: Int) -> UIImage {
        let W = max(64, size), H = max(64, size)

        // 0xC0FF_EE00 as signed Int32
        let seed: Int32 = -1056969216
        let macro = GKNoise(GKBillowNoiseSource(frequency: 0.7, octaveCount: 3, persistence: 0.55, lacunarity: 2.0, seed: seed))
        let mMap = GKNoiseMap(macro, size: vector_double2(1, 1), origin: vector_double2(0, 0),
                              sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)

        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                let v = Double(mMap.value(at: vector_int2(Int32(x), Int32(y)))) * 0.5 + 0.5
                // 0.90 .. 1.10 → clamp to [0,1] before packing to 8-bit
                let b = clamp(0.90 + 0.20 * v, lower: 0.0, upper: 1.0)
                let c = toU8(b)
                px[i + 0] = c
                px[i + 1] = c
                px[i + 2] = c
                px[i + 3] = 255
            }
        }
        return imageFromRGBA(px: &px, width: W, height: H)
    }

    // MARK: Utils

    static func imageFromRGBA(px: inout [UInt8], width: Int, height: Int) -> UIImage {
        let bpr = width * 4
        let data = CFDataCreate(nil, &px, px.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cg = CGImage(width: width, height: height,
                         bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                         space: cs, bitmapInfo: info,
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    @inline(__always)
    static func toU8(_ x: Double) -> UInt8 {
        let v = Int((x * 255.0).rounded())
        return UInt8(clamping: v)
    }

    @inline(__always)
    static func clamp<T: Comparable>(_ x: T, lower: T, upper: T) -> T { min(max(x, lower), upper) }

    @inline(__always)
    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
}
