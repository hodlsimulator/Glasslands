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
import CoreGraphics
import simd

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

enum SceneKitHelpers {
    private static var _groundDetail: UIImage?

    static func groundDetailTexture(size: Int = 256) -> UIImage {
        if let img = _groundDetail { return img }
        let img = groundDetailImage(size: size)
        _groundDetail = img
        return img
    }

    @MainActor
    static func skyboxImages(size: Int) -> [UIImage] {
        // Kept for any synchronous/main use
        let size = max(64, size)
        let W = size, H = size

        let zenith  = SIMD3<Double>(0.50, 0.74, 0.92)
        let horizon = SIMD3<Double>(0.86, 0.93, 0.98)

        @inline(__always) func smooth(_ x: Double) -> Double {
            let t = max(0.0, min(1.0, x))
            return t * t * (3.0 - 2.0 * t)
        }

        func dir(forFace i: Int, u: Double, v: Double) -> SIMD3<Double> {
            switch i {
            case 0: return SIMD3( 1, v, -u)
            case 1: return SIMD3(-1, v,  u)
            case 2: return SIMD3( u, 1,  v)
            case 3: return SIMD3( u,-1, -v)
            case 4: return SIMD3( u, v,  1)
            default:return SIMD3(-u, v, -1)
            }
        }

        func makeFace() -> (Int) -> UIImage {
            return { face in
                var bytes = [UInt8](repeating: 0, count: W * H * 4)
                let bpr = W * 4
                for y in 0..<H {
                    for x in 0..<W {
                        let u = (Double(x) / Double(W - 1)) * 2.0 - 1.0
                        let v = (Double(y) / Double(H - 1)) * 2.0 - 1.0
                        let d = simd_normalize(dir(forFace: face, u: u, v: v))
                        let t = smooth((d.y + 1.0) * 0.5)
                        let c = horizon * (1.0 - t) + zenith * t
                        let r = UInt8(max(0, min(255, Int(c.x * 255.0))))
                        let g = UInt8(max(0, min(255, Int(c.y * 255.0))))
                        let b = UInt8(max(0, min(255, Int(c.z * 255.0))))
                        let i = (y * W + x) * 4
                        bytes[i+0] = r; bytes[i+1] = g; bytes[i+2] = b; bytes[i+3] = 255
                    }
                }
                let cs = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                let img: UIImage = bytes.withUnsafeMutableBytes { raw in
                    let ctx = CGContext(
                        data: raw.baseAddress,
                        width: W,
                        height: H,
                        bitsPerComponent: 8,
                        bytesPerRow: bpr,
                        space: cs,
                        bitmapInfo: bitmapInfo.rawValue
                    )!
                    let cg = ctx.makeImage()!
                    return UIImage(cgImage: cg, scale: 1, orientation: .up)
                }
                return img
            }
        }

        let faceFn = makeFace()
        return [0, 1, 2, 3, 4, 5].map(faceFn)
    }

    static func sunImage(diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5

        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            let img = UIImage(); UIGraphicsEndImageContext(); return img
        }

        let cs = CGColorSpaceCreateDeviceRGB()

        let glow = [UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95).cgColor,
                    UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.0).cgColor] as CFArray
        let gg = CGGradient(colorsSpace: cs, colors: glow, locations: [0, 1])!
        ctx.drawRadialGradient(gg, startCenter: CGPoint(x: r, y: r), startRadius: 0, endCenter: CGPoint(x: r, y: r), endRadius: r, options: [])

        let coreRect = CGRect(x: size.width*0.5 - r*0.58, y: size.height*0.5 - r*0.58, width: r*1.16, height: r*1.16)
        ctx.setFillColor(UIColor(white: 1.0, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: coreRect)

        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    static func groundDetailImage(size: Int) -> UIImage {
        let W = max(64, size), H = max(64, size)

        let src = GKPerlinNoiseSource(frequency: 2.0, octaveCount: 5, persistence: 0.55, lacunarity: 2.1, seed: 424242)
        let noise = GKNoise(src)
        let map = GKNoiseMap(
            noise,
            size: vector_double2(1, 1),
            origin: vector_double2(0, 0),
            sampleCount: vector_int2(Int32(W), Int32(H)),
            seamless: true
        )

        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        let bpr = W * 4

        for y in 0..<H {
            for x in 0..<W {
                let v = map.value(at: vector_int2(Int32(x), Int32(y))) // -1..1
                let n = pow(max(0, min(1, (v * 0.5 + 0.5))), 1.2)
                let g = UInt8(max(0, min(255, Int(n * 255.0))))
                let i = (y * W + x) * 4
                bytes[i+0] = g
                bytes[i+1] = g
                bytes[i+2] = g
                bytes[i+3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let img: UIImage = bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress,
                width: W,
                height: H,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: cs,
                bitmapInfo: bitmapInfo.rawValue
            )!
            let cg = ctx.makeImage()!
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
        return img
    }
}
