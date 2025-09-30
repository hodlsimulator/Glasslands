//
//  SceneKitHelpers.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Small SceneKit utilities + procedural images (skybox, sun, clouds, ground detail).
//

import SceneKit
import UIKit
import GameplayKit

// MARK: - Convenience

extension SCNVector3 {
    static var zero: SCNVector3 { SCNVector3(0, 0, 0) }
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    init(_ v: SIMD3<Float>) { self.init(v.x, v.y, v.z) }
}

/// Build a SceneKit vertex-colour source from UIColors.
func geometrySourceForVertexColors(_ colors: [UIColor]) -> SCNGeometrySource {
    var floats: [Float] = []
    floats.reserveCapacity(colors.count * 4)
    for c in colors {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        floats.append(Float(r)); floats.append(Float(g)); floats.append(Float(b)); floats.append(Float(a))
    }
    let stride = MemoryLayout<Float>.size * 4
    let data = floats.withUnsafeBytes { Data($0) }
    return SCNGeometrySource(
        data: data,
        semantic: .color,
        vectorCount: colors.count,
        usesFloatComponents: true,
        componentsPerVector: 4,
        bytesPerComponent: MemoryLayout<Float>.size,
        dataOffset: 0,
        dataStride: stride
    )
}

// MARK: - Procedural images

enum SceneKitHelpers {

    // Expose a function to match call sites:
    static func groundDetailTexture(size: Int = 128) -> UIImage {
        groundDetailImage(size: size)
    }

    // Seamless cube-map sky: colour depends on the *direction vector*,
    // not per-face gradients, so there are no seams at edges or corners.
    static func skyboxImages(size: Int) -> [UIImage] {
        let W = max(64, size), H = max(64, size)

        // Colours
        let zenith   = SIMD3<Double>(0.50, 0.74, 0.92)  // top
        let horizon  = SIMD3<Double>(0.86, 0.93, 0.98)  // near horizon

        // Smoothstep helper
        @inline(__always) func smooth(_ x: Double) -> Double {
            let t = max(0.0, min(1.0, x))
            return t * t * (3.0 - 2.0 * t)
        }

        // Direction from face + (u,v) ∈ [-1,1]^2
        func dir(forFace i: Int, u: Double, v: Double) -> SIMD3<Double> {
            switch i {
            case 0: return SIMD3<Double>( 1, v, -u) // +X
            case 1: return SIMD3<Double>(-1, v,  u) // -X
            case 2: return SIMD3<Double>( u, 1,  v) // +Y
            case 3: return SIMD3<Double>( u,-1, -v) // -Y
            case 4: return SIMD3<Double>( u, v,  1) // +Z
            default:return SIMD3<Double>(-u, v, -1) // -Z
            }
        }

        func makeFace(_ face: Int) -> UIImage {
            var bytes = [UInt8](repeating: 0, count: W * H * 4)
            let bpr = W * 4

            for y in 0..<H {
                // v: +1 at top, -1 at bottom (matches cube map conventions)
                let v = 1.0 - 2.0 * Double(y) / Double(H - 1)
                for x in 0..<W {
                    let u = -1.0 + 2.0 * Double(x) / Double(W - 1)

                    // Normalised direction
                    var d = dir(forFace: face, u: u, v: v)
                    let len = max(1e-9, sqrt(d.x*d.x + d.y*d.y + d.z*d.z))
                    d /= len

                    // Blend by vertical component (d.y). Bias a little towards the horizon.
                    var t = (d.y + 1.0) * 0.5
                    t = smooth(pow(t, 0.82))

                    let c = horizon + (zenith - horizon) * t
                    let r = UInt8(max(0, min(255, Int(c.x * 255.0))))
                    let g = UInt8(max(0, min(255, Int(c.y * 255.0))))
                    let b = UInt8(max(0, min(255, Int(c.z * 255.0))))

                    let i = y * bpr + x * 4
                    bytes[i + 0] = r
                    bytes[i + 1] = g
                    bytes[i + 2] = b
                    bytes[i + 3] = 255
                }
            }

            let cs = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            )
            return bytes.withUnsafeMutableBytes { raw -> UIImage in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: W, height: H,
                    bitsPerComponent: 8, bytesPerRow: bpr,
                    space: cs, bitmapInfo: bitmapInfo.rawValue
                ), let cg = ctx.makeImage() else {
                    return UIImage()
                }
                return UIImage(cgImage: cg, scale: 1, orientation: .up)
            }
        }

        // Order required by SceneKit: +X, -X, +Y, -Y, +Z, -Z
        return [0, 1, 2, 3, 4, 5].map { makeFace($0) }
    }

    // Soft sun disc with gentle glow (premultiplied RGBA)
    static func sunImage(diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            let img = UIImage(); UIGraphicsEndImageContext(); return img
        }

        let cs = CGColorSpaceCreateDeviceRGB()

        // Outer glow
        let glow = [UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95).cgColor,
                    UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor] as CFArray
        let gg = CGGradient(colorsSpace: cs, colors: glow, locations: [0, 1])!
        ctx.drawRadialGradient(gg,
                               startCenter: CGPoint(x: r, y: r), startRadius: 0,
                               endCenter: CGPoint(x: r, y: r), endRadius: r,
                               options: [])

        // Core
        let coreRect = CGRect(x: size.width*0.5 - r*0.58, y: size.height*0.5 - r*0.58,
                              width: r*1.16, height: r*1.16)
        ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: coreRect)

        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    /// Horizontally wrapping cloud alpha (equirectangular). Polar regions fade out.
    static func cloudsEquirect(width: Int, height: Int, seed: Int32 = 424242) -> UIImage {
        let W = max(256, width), H = max(128, height)

        // Perlin noise (seamless)
        let src = GKPerlinNoiseSource(frequency: 1.6, octaveCount: 5, persistence: 0.55, lacunarity: 2.0, seed: seed)
        let noise = GKNoise(src)
        let map  = GKNoiseMap(noise,
                              size: vector_double2(1, 1),
                              origin: vector_double2(0, 0),
                              sampleCount: vector_int2(Int32(W), Int32(H)),
                              seamless: true)

        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        let bpr = W * 4

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            if x <= a { return 0 }
            if x >= b { return 1 }
            let t = (x - a) / (b - a)
            return t * t * (3 - 2 * t)
        }

        let threshold = 0.54
        let softness  = 0.18
        let gain      = 0.95
        let polarExp  = 1.6

        for y in 0..<H {
            let v = 1.0 - 2.0 * Double(y) / Double(H - 1)      // +1 at top, -1 at bottom
            let polarFade = pow(1.0 - abs(v), polarExp)         // fade near poles
            for x in 0..<W {
                let n  = Double(map.value(at: vector_int2(Int32(x), Int32(y))))
                let a  = smooth(threshold - softness, threshold + softness, (n * gain + 1.0) * 0.5)
                let alpha = UInt8(max(0, min(255, Int(a * polarFade * 255.0))))

                // white clouds in alpha; RGB left at 0 (will tint in material if needed)
                let i = y * bpr + x * 4
                bytes[i + 0] = 255
                bytes[i + 1] = 255
                bytes[i + 2] = 255
                bytes[i + 3] = alpha
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return bytes.withUnsafeMutableBytes { raw -> UIImage in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: bpr,
                space: cs, bitmapInfo: bitmapInfo.rawValue
            ), let cg = ctx.makeImage() else {
                return UIImage()
            }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
    }

    /// Tiny tileable ground detail (stipple).
    static func groundDetailImage(size: Int) -> UIImage {
        let W = max(64, size), H = max(64, size)
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        let bpr = W * 4

        func val(_ x: Int, _ y: Int) -> Float {
            let fx = Float(x), fy = Float(y)
            let s1 = sin((fx * 0.10) * .pi / 32) * cos((fy * 0.10) * .pi / 32)
            let s2 = sin((fx * 0.35) * .pi / 32) * sin((fy * 0.27) * .pi / 32)
            return max(0.0, min(1.0, 0.55 + 0.25 * s1 + 0.20 * s2))
        }

        for y in 0..<H {
            for x in 0..<W {
                let v = UInt8(val(x, y) * 255.0)
                let i = y * bpr + x * 4
                bytes[i + 0] = v
                bytes[i + 1] = v
                bytes[i + 2] = v
                bytes[i + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return bytes.withUnsafeMutableBytes { raw -> UIImage in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: bpr,
                space: cs, bitmapInfo: bitmapInfo.rawValue
            ), let cg = ctx.makeImage() else {
                return UIImage()
            }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
    }
}
