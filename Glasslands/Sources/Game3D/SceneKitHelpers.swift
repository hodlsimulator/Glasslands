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

// Per‑vertex colour source for iOS (RGBA float)
func geometrySourceForVertexColors(_ colors: [UIColor]) -> SCNGeometrySource {
    var floats: [Float] = []
    floats.reserveCapacity(colors.count * 4)
    for c in colors {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        floats.append(Float(r)); floats.append(Float(g))
        floats.append(Float(b)); floats.append(Float(a))
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

// A 2:1 equirectangular sky gradient (top→horizon)
// Horizontally uniform → set wrapS = .repeat on the dome (no seam).
func skyGradientEquirect(width: Int, height: Int) -> UIImage {
    let W = max(64, width)
    let H = max(32, height)
    let size = CGSize(width: W, height: H)

    // Colours (soft blue → lighter near horizon)
    let top = UIColor(red: 0.50, green: 0.74, blue: 0.92, alpha: 1)
    let mid = UIColor(red: 0.66, green: 0.84, blue: 0.95, alpha: 1)
    let bot = UIColor(red: 0.86, green: 0.93, blue: 0.98, alpha: 1)

    UIGraphicsBeginImageContextWithOptions(size, true, 1)
    guard let ctx = UIGraphicsGetCurrentContext() else {
        let img = UIImage(); UIGraphicsEndImageContext(); return img
    }

    let colors = [top.cgColor, mid.cgColor, bot.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!

    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: size.width * 0.5, y: 0),
        end: CGPoint(x: size.width * 0.5, y: size.height),
        options: []
    )

    let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()
    return img
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
    let glowColors = [
        UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95).cgColor,
        UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor
    ] as CFArray
    let glowGrad = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glowGrad,
                           startCenter: CGPoint(x: r, y: r), startRadius: 0,
                           endCenter: CGPoint(x: r, y: r),   endRadius: r,
                           options: [])
    // Core disc
    let coreRect = CGRect(x: size.width*0.5 - r*0.58,
                          y: size.height*0.5 - r*0.58,
                          width: r*1.16, height: r*1.16)
    ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: coreRect)
    let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()
    return img
}

/// Equirectangular, seamless cloud **alpha** map (premultiplied RGBA), 2:1 aspect.
func cloudsEquirect(width: Int, height: Int, seed: Int32 = 424242) -> UIImage {
    let W = max(256, width)
    let H = max(128, height)

    // Puffy fractal Perlin
    let src = GKPerlinNoiseSource(frequency: 1.6,
                                  octaveCount: 5,
                                  persistence: 0.55,
                                  lacunarity: 2.0,
                                  seed: seed)
    let noise = GKNoise(src)
    let map = GKNoiseMap(noise,
                         size: vector_double2(1, 1),
                         origin: vector_double2(0, 0),
                         sampleCount: vector_int2(Int32(W), Int32(H)),
                         seamless: true) // horizontally seamless

    var bytes = [UInt8](repeating: 0, count: W * H * 4)

    @inline(__always)
    func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if x <= a { return 0 }
        if x >= b { return 1 }
        let t = (x - a) / (b - a)
        return t * t * (3 - 2 * t)
    }

    let threshold = 0.54
    let softness  = 0.18
    let gain: Double = 0.95

    var off = 0
    for y in 0..<H {
        for x in 0..<W {
            let n = Double(map.value(at: vector_int2(Int32(x), Int32(y))))
            let v01 = (n * 0.5) + 0.5
            let a = gain * smoothstep(threshold - softness,
                                      threshold + softness,
                                      v01)
            let aa = UInt8(max(0, min(255, Int(a * 255))))
            bytes[off+0] = aa
            bytes[off+1] = aa
            bytes[off+2] = aa
            bytes[off+3] = aa
            off += 4
        }
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let bitsPerComp = 8
    let bytesPerRow = W * 4
    var mutable = bytes // CGContext needs a mutable pointer

    guard let ctx = CGContext(data: &mutable,
                              width: W, height: H,
                              bitsPerComponent: bitsPerComp,
                              bytesPerRow: bytesPerRow,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return UIImage() }

    guard let cg = ctx.makeImage() else { return UIImage() }
    return UIImage(cgImage: cg)
}
