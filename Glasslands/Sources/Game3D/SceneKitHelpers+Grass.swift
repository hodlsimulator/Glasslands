//
//  SceneKitHelpers+Grass.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Procedural, tileable grass textures (albedo, normal, macro) with wrap-aware mipmaps.
//  Supplies MTLTextures so SceneKit never generates non-seamless mips that cause grid lines.
//

import UIKit
import GameplayKit
import CoreGraphics
import simd
import Metal

extension SceneKitHelpers {

    // Integer repeats per chunk avoid visible phase jumps between chunks.
    static let grassRepeatsPerTile: CGFloat = 4.0
    static let grassMacroRepeatsAcrossChunk: CGFloat = 8.0

    // Cache (MTL textures)
    private static var _albedoTex: MTLTexture?
    private static var _normalTex: MTLTexture?
    private static var _macroTex: MTLTexture?

    // Public texture accessors (MTLTexture)
    static func grassAlbedoTextureMTL(size: Int = 512) -> MTLTexture {
        if let t = _albedoTex { return t }
        let (w, h) = (max(64, size), max(64, size))
        let base = grassAlbedoRGBA(size: w)
        let tex = makeSeamlessTextureRGBA(width: w, height: h, baseRGBA: base, isNormal: false)
        _albedoTex = tex
        return tex
    }

    static func grassNormalTextureMTL(size: Int = 512, strength: Double = 1.6) -> MTLTexture {
        if let t = _normalTex { return t }
        let (w, h) = (max(64, size), max(64, size))
        let base = grassNormalRGBA(size: w, strength: strength)
        let tex = makeSeamlessTextureRGBA(width: w, height: h, baseRGBA: base, isNormal: true)
        _normalTex = tex
        return tex
    }

    static func grassMacroVariationTextureMTL(size: Int = 256) -> MTLTexture {
        if let t = _macroTex { return t }
        let (w, h) = (max(64, size), max(64, size))
        let base = grassMacroRGBA(size: w)
        let tex = makeSeamlessTextureRGBA(width: w, height: h, baseRGBA: base, isNormal: false)
        _macroTex = tex
        return tex
    }

    // Legacy UIImage accessors (kept for compatibility elsewhere if needed)
    private static var _grassAlbedoImg: UIImage?
    private static var _grassNormalImg: UIImage?
    private static var _grassMacroImg: UIImage?

    static func grassAlbedoTexture(size: Int = 512) -> UIImage {
        if let img = _grassAlbedoImg { return img }
        let (w, h) = (max(64, size), max(64, size))
        var rgba = grassAlbedoRGBA(size: w)
        let img = imageFromRGBA(px: &rgba, width: w, height: h)
        _grassAlbedoImg = img
        return img
    }

    static func grassNormalTexture(size: Int = 512, strength: Double = 1.6) -> UIImage {
        if let img = _grassNormalImg { return img }
        let (w, h) = (max(64, size), max(64, size))
        var rgba = grassNormalRGBA(size: w, strength: strength)
        let img = imageFromRGBA(px: &rgba, width: w, height: h)
        _grassNormalImg = img
        return img
    }

    static func grassMacroVariationTexture(size: Int = 256) -> UIImage {
        if let img = _grassMacroImg { return img }
        let (w, h) = (max(64, size), max(64, size))
        var rgba = grassMacroRGBA(size: w)
        let img = imageFromRGBA(px: &rgba, width: w, height: h)
        _grassMacroImg = img
        return img
    }
}

// MARK: - Base RGBA generators (seamless tiles)

private extension SceneKitHelpers {

    // Albedo: subtle variation + rare straw flecks. Seamless.
    static func grassAlbedoRGBA(size: Int) -> [UInt8] {
        let W = size, H = size
        let seedBase: Int32 = 0x4A10_BA5E
        let grain = GKNoise(GKPerlinNoiseSource(frequency: 6.0, octaveCount: 4, persistence: 0.52, lacunarity: 2.1, seed: seedBase))
        let lumps = GKNoise(GKBillowNoiseSource(frequency: 1.2, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: seedBase &+ 101))
        let speck = GKNoise(GKRidgedNoiseSource(frequency: 8.0, octaveCount: 2, lacunarity: 2.0, seed: seedBase &+ 202))

        let grainMap = GKNoiseMap(grain, size: vector_double2(1,1), origin: vector_double2(0,0),
                                  sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)
        let lumpsMap = GKNoiseMap(lumps, size: vector_double2(1,1), origin: vector_double2(0,0),
                                  sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)
        let speckMap = GKNoiseMap(speck, size: vector_double2(1,1), origin: vector_double2(0,0),
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
        return px
    }

    // Normal map: from seamless height; then packed to RGB.
    static func grassNormalRGBA(size: Int, strength: Double) -> [UInt8] {
        let W = size, H = size
        let seed: Int32 = -1640531527 // 0x9E37_79B9
        let hNoise = GKNoise(GKPerlinNoiseSource(frequency: 5.0, octaveCount: 4, persistence: 0.52, lacunarity: 2.0, seed: seed))
        let hMap = GKNoiseMap(hNoise, size: vector_double2(1,1), origin: vector_double2(0,0),
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
                let i = (y * W + x) * 4
                px[i + 0] = toU8(clamp((N.x * 0.5) + 0.5, lower: 0.0, upper: 1.0))
                px[i + 1] = toU8(clamp((N.y * 0.5) + 0.5, lower: 0.0, upper: 1.0))
                px[i + 2] = toU8(clamp((N.z * 0.5) + 0.5, lower: 0.0, upper: 1.0))
                px[i + 3] = 255
            }
        }
        return px
    }

    // Macro brightness (used as multiply); near 1.0 with subtle variation.
    static func grassMacroRGBA(size: Int) -> [UInt8] {
        let W = size, H = size
        let seed: Int32 = -1056969216 // 0xC0FF_EE00
        let macro = GKNoise(GKBillowNoiseSource(frequency: 0.7, octaveCount: 3, persistence: 0.55, lacunarity: 2.0, seed: seed))
        let mMap = GKNoiseMap(macro, size: vector_double2(1,1), origin: vector_double2(0,0),
                              sampleCount: vector_int2(Int32(W), Int32(H)), seamless: true)

        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                let v = Double(mMap.value(at: vector_int2(Int32(x), Int32(y)))) * 0.5 + 0.5
                let b = clamp(0.90 + 0.20 * v, lower: 0.0, upper: 1.0)
                let c = toU8(b)
                px[i + 0] = c; px[i + 1] = c; px[i + 2] = c; px[i + 3] = 255
            }
        }
        return px
    }
}

// MARK: - Seamless mipmap builder (wrap-aware downsampling) → MTLTexture

private extension SceneKitHelpers {

    static func makeSeamlessTextureRGBA(width: Int, height: Int, baseRGBA: [UInt8], isNormal: Bool) -> MTLTexture {
        let w = width, h = height
        let levels = max(1, Int(floor(log2(Double(max(w, h))))) + 1)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device unavailable")
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        desc.mipmapLevelCount = levels
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create MTLTexture")
        }

        var levelRGBA: [UInt8] = baseRGBA
        var cw = w
        var ch = h

        tex.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: levelRGBA, bytesPerRow: cw * 4)

        if isNormal {
            for level in 1..<levels {
                let nextW = max(1, cw >> 1), nextH = max(1, ch >> 1)
                let down = downsampleNormalRGBAWrap(src: levelRGBA, width: cw, height: ch, nextW: nextW, nextH: nextH)
                levelRGBA = down
                cw = nextW; ch = nextH
                tex.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: level, withBytes: levelRGBA, bytesPerRow: cw * 4)
            }
        } else {
            for level in 1..<levels {
                let nextW = max(1, cw >> 1), nextH = max(1, ch >> 1)
                let down = downsampleRGBAWrap(src: levelRGBA, width: cw, height: ch, nextW: nextW, nextH: nextH)
                levelRGBA = down
                cw = nextW; ch = nextH
                tex.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: level, withBytes: levelRGBA, bytesPerRow: cw * 4)
            }
        }

        return tex
    }

    // Box-filter 2× downsample with wrap addressing (seamless).
    static func downsampleRGBAWrap(src: [UInt8], width W: Int, height H: Int, nextW: Int, nextH: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: nextW * nextH * 4)
        for y in 0..<nextH {
            for x in 0..<nextW {
                let x0 = (2*x) % W, x1 = (2*x + 1) % W
                let y0 = (2*y) % H, y1 = (2*y + 1) % H
                var r = 0, g = 0, b = 0, a = 0
                for yy in [y0, y1] {
                    for xx in [x0, x1] {
                        let i = (yy * W + xx) * 4
                        r += Int(src[i + 0]); g += Int(src[i + 1]); b += Int(src[i + 2]); a += Int(src[i + 3])
                    }
                }
                let o = (y * nextW + x) * 4
                out[o + 0] = UInt8((r + 2) >> 2)
                out[o + 1] = UInt8((g + 2) >> 2)
                out[o + 2] = UInt8((b + 2) >> 2)
                out[o + 3] = UInt8((a + 2) >> 2)
            }
        }
        return out
    }

    // Normal-map aware downsample: decode [-1,1], average, renormalise, repack.
    static func downsampleNormalRGBAWrap(src: [UInt8], width W: Int, height H: Int, nextW: Int, nextH: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: nextW * nextH * 4)
        for y in 0..<nextH {
            for x in 0..<nextW {
                let x0 = (2*x) % W, x1 = (2*x + 1) % W
                let y0 = (2*y) % H, y1 = (2*y + 1) % H
                var acc = SIMD3<Double>(0, 0, 0)
                func sample(_ xx: Int, _ yy: Int) {
                    let i = (yy * W + xx) * 4
                    let nx = (Double(src[i + 0]) / 255.0) * 2.0 - 1.0
                    let ny = (Double(src[i + 1]) / 255.0) * 2.0 - 1.0
                    let nz = (Double(src[i + 2]) / 255.0) * 2.0 - 1.0
                    acc += SIMD3<Double>(nx, ny, nz)
                }
                sample(x0, y0); sample(x1, y0); sample(x0, y1); sample(x1, y1)
                var N = acc / 4.0
                let len = max(1e-6, sqrt(N.x*N.x + N.y*N.y + N.z*N.z))
                N /= len
                let o = (y * nextW + x) * 4
                out[o + 0] = toU8((N.x * 0.5) + 0.5)
                out[o + 1] = toU8((N.y * 0.5) + 0.5)
                out[o + 2] = toU8((N.z * 0.5) + 0.5)
                out[o + 3] = 255
            }
        }
        return out
    }
}

// MARK: - Utilities

private extension SceneKitHelpers {
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
