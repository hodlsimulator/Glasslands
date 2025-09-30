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

// Convenience zero and SIMD bridge
extension SCNVector3 {
    static var zero: SCNVector3 { SCNVector3(0, 0, 0) }
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    init(_ v: SIMD3<Float>) { self.init(v.x, v.y, v.z) }
}

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

// MARK: - Sky

/// Cube map images for SceneKit background — no meridian seam possible.
enum SceneKitHelpers {
    static func skyboxImages(size: Int) -> [UIImage] {
        // Faces: +X, -X, +Y, -Y, +Z, -Z
        let cTop = UIColor(red: 0.50, green: 0.74, blue: 0.92, alpha: 1)     // zenith
        let cHorizon = UIColor(red: 0.86, green: 0.93, blue: 0.98, alpha: 1)

        func face(_ verticalFlip: Bool) -> UIImage {
            let W = max(64, size), H = max(64, size)
            let sz = CGSize(width: W, height: H)
            UIGraphicsBeginImageContextWithOptions(sz, true, 1)
            let ctx = UIGraphicsGetCurrentContext()!
            let space = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: space,
                                  colors: [cTop.cgColor, cHorizon.cgColor] as CFArray,
                                  locations: [0, 1])!
            let start = CGPoint(x: sz.width/2, y: verticalFlip ? sz.height : 0)
            let end   = CGPoint(x: sz.width/2, y: verticalFlip ? 0 : sz.height)
            ctx.drawLinearGradient(grad, start: start, end: end, options: [])
            let img = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()
            return img
        }

        return [
            face(false), face(false),  // +X, -X
            face(false), face(true),   // +Y (up), -Y (down; fade towards horizon)
            face(false), face(false)   // +Z, -Z
        ]
    }

    // Soft sun disc with a gentle glow (premultiplied RGBA)
    static func sunImage(diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            let img = UIImage(); UIGraphicsEndImageContext(); return img
        }

        // Outer glow
        let space = CGColorSpaceCreateDeviceRGB()
        let glowColors = [
            UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95).cgColor,
            UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor
        ] as CFArray
        let glowGrad = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: r, y: r), startRadius: 0,
            endCenter: CGPoint(x: r, y: r), endRadius: r,
            options: []
        )

        // Core disc
        let coreRect = CGRect(x: size.width*0.5 - r*0.58, y: size.height*0.5 - r*0.58, width: r*1.16, height: r*1.16)
        ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: coreRect)

        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    /// Seamless, horizontally wrapping cloud alpha map (with polar fade).
    static func cloudsEquirect(width: Int, height: Int, seed: Int32 = 424242) -> UIImage {
        let W = max(256, width)
        let H = max(128, height)

        let src = GKPerlinNoiseSource(frequency: 1.6, octaveCount: 5, persistence: 0.55, lacunarity: 2.0, seed: seed)
        let noise = GKNoise(src)
        let map = GKNoiseMap(noise,
                             size: vector_double2(1, 1),
                             origin: vector_double2(0, 0),
                             sampleCount: vector_int2(Int32(W), Int32(H)),
                             seamless: true)

        var bytes = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            if x <= a { return 0 }
            if x >= b { return 1 }
            let t = (x - a) / (b - a)
            return t * t * (3 - 2 * t)
        }

        let threshold = 0.54
        let softness  = 0.18
        let gain: Double = 0.95
        let polarFadeExp = 1.6

        var off = 0
        for y in 0..<H {
            let v = Double(y) / Double(H-1)
            let polar = pow(sin(.pi * v), polarFadeExp) // 0 at poles → 1 at mid
            for x in 0..<W {
                let n = Double(map.value(at: vector_int2(Int32(x), Int32(y))))
                let a = smoothstep(threshold - softness, threshold + softness, (n * 0.5 + 0.5) * gain)
                let alpha = a * polar

                let r = UInt8((1.0 * alpha) * 255.0)
                let g = UInt8((1.0 * alpha) * 255.0)
                let b = UInt8((1.0 * alpha) * 255.0)
                let A = UInt8(alpha * 255.0)
                bytes[off + 0] = r
                bytes[off + 1] = g
                bytes[off + 2] = b
                bytes[off + 3] = A
                off += 4
            }
        }

        let data = Data(bytes)
        let space = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: data as CFData)!
        let bmpInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: W * 4,
            space: space,
            bitmapInfo: bmpInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!

        return UIImage(cgImage: cg)
    }

    /// Small, seamless greyscale noise for ground micro-detail (tileable).
    static func groundDetailTexture(size: Int) -> UIImage {
        let W = max(64, size), H = max(64, size)
        var bytes = [UInt8](repeating: 0, count: W * H * 4)

        func val(_ x: Int, _ y: Int) -> Float {
            // Cheap tileable noise using cos/sin; looks like fine soil/stipple.
            let fx = Float(x), fy = Float(y)
            let s = sin((fx * 0.10) * .pi / 32) * cos((fy * 0.10) * .pi / 32)
            let s2 = sin((fx * 0.35) * .pi / 32) * sin((fy * 0.27) * .pi / 32)
            let v = 0.55 + 0.25 * s + 0.20 * s2
            return max(0.0, min(1.0, v))
        }

        var o = 0
        for y in 0..<H {
            for x in 0..<W {
                let g = UInt8(val(x, y) * 255)
                bytes[o+0] = g; bytes[o+1] = g; bytes[o+2] = g; bytes[o+3] = 255
                o += 4
            }
        }

        let data = Data(bytes)
        let space = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: data as CFData)!
        let cg = CGImage(
            width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: W * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg)
    }
}
