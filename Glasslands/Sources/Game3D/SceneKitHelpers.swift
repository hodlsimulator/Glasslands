//
//  SceneKitHelpers.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import SceneKit
import UIKit
import GameplayKit

// Convenience zero and SIMD bridge
extension SCNVector3 {
    static var zero: SCNVector3 { SCNVector3(0,0,0) }
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
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

// Bridge for GKRandomSource to Swift RNG protocol
struct RandomAdaptor: RandomNumberGenerator {
    private let src: GKRandomSource
    init(_ src: GKRandomSource) { self.src = src }
    mutating func next() -> UInt64 {
        // 32-bit at a time
        let a = UInt64(bitPattern: Int64(src.nextInt()))
        let b = UInt64(bitPattern: Int64(src.nextInt()))
        return (a << 32) ^ (b & 0xFFFF_FFFF)
    }
}
