//
//  SceneKitHelpers.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Small SceneKit utilities + procedural images (sky gradient, sun, clouds).
//

import SceneKit
import UIKit
import GameplayKit

// Convenience zero and SIMD bridge
extension SCNVector3 {
    static var zero: SCNVector3 { SCNVector3(0,0,0) }
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    init(_ v: SIMD3<Float>) { self.init(v.x, v.y, v.z) }
}

// Per-vertex colour source for iOS (RGBA float)
func geometrySourceForVertexColors(_ colors: [UIColor]) -> SCNGeometrySource {
    var floats: [Float] = []
    floats.reserveCapacity(colors.count * 4)
    for c in colors {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        floats.append(Float(r))
        floats.append(Float(g))
        floats.append(Float(b))
        floats.append(Float(a))
    }
    let stride = MemoryLayout<Float>.size * 4
    let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
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

// Simple vertical gradient image for sky
func gradientImage(top: UIColor, bottom: UIColor, height: Int) -> UIImage {
    let size = CGSize(width: 2, height: height)
    UIGraphicsBeginImageContextWithOptions(size, true, 1)
    guard let ctx = UIGraphicsGetCurrentContext() else {
        let img = UIImage(); UIGraphicsEndImageContext(); return img
    }
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0,1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 1, y: 0), end: CGPoint(x: 1, y: CGFloat(height)), options: [])
    let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()
    return img.resizableImage(withCapInsets: .zero, resizingMode: .stretch)
}

// Soft sun disc with a gentle glow (premultiplied RGBA)
func sunImage(diameter: Int) -> UIImage {
    let d = max(8, diameter)
    let size = CGSize(width: d, height: d)
    let r = min(size.width, size.height) * 0.5

    UIGraphicsBeginImageContextWithOptions(size, false, 1)
    guard let ctx = UIGraphicsGetCurrentContext() else {
        let img = UIImage(); UIGraphicsEndImageContext(); return img
    }

    // Outer glow
    let space = CGColorSpaceCreateDeviceRGB()
    let glowColors = [UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.75).cgColor,
                      UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor] as CFArray
    let glowGrad = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glowGrad,
                           startCenter: CGPoint(x: r, y: r), startRadius: 0,
                           endCenter: CGPoint(x: r, y: r), endRadius: r,
                           options: [])

    // Core disc (slightly smaller than full)
    let coreRect = CGRect(x: size.width*0.5 - r*0.6, y: size.height*0.5 - r*0.6, width: r*1.2, height: r*1.2)
    ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: coreRect)

    let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()
    return img
}

// Seamless Perlin-noise clouds alpha mask (premultiplied RGBA)
func cloudsImage(size: Int, seed: Int32 = 1337) -> UIImage {
    let N = max(64, size)

    // Tileable noise map
    let src  = GKPerlinNoiseSource(frequency: 1.2, octaveCount: 5, persistence: 0.55, lacunarity: 2.0, seed: seed)
    let noise = GKNoise(src)
    let map = GKNoiseMap(noise,
                         size: vector_double2(1, 1),
                         origin: vector_double2(0, 0),
                         sampleCount: vector_int2(Int32(N), Int32(N)),
                         seamless: true)

    // Pixels (premultiplied RGBA)
    var bytes = [UInt8](repeating: 0, count: N * N * 4)
    var off = 0

    @inline(__always) func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if x <= a { return 0 }
        if x >= b { return 1 }
        let t = (x - a) / (b - a)
        return t * t * (3 - 2 * t)
    }

    // Threshold and softness
    let threshold = 0.55
    let softness  = 0.15
    let gain: Double = 0.95 // overall alpha gain

    for y in 0..<N {
        for x in 0..<N {
            let v = Double(map.value(at: vector_int2(Int32(x), Int32(y)))) // ~[-1,1]
            let u = max(0.0, min(1.0, (v + 1.0) * 0.5))                    // [0,1]
            let a = smoothstep(threshold - softness, threshold + softness, u) * gain

            // Premultiplied white = alpha
            let a8 = UInt8(max(0, min(255, Int(a * 255.0))))
            bytes[off + 0] = a8
            bytes[off + 1] = a8
            bytes[off + 2] = a8
            bytes[off + 3] = a8
            off += 4
        }
    }

    let provider = CGDataProvider(data: NSData(bytes: &bytes, length: bytes.count))!
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let cg = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: N * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return UIImage(cgImage: cg)
}
