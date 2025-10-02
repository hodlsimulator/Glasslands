//
//  SceneKitHelpers+Ground.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//
//  Procedural ground normal map created from the same noise as the ground detail texture.
//

import UIKit
import GameplayKit
import simd

extension SceneKitHelpers {

    private static var _groundNormal: UIImage?

    static func groundDetailNormalTexture(size: Int = 512, strength: Double = 2.0) -> UIImage {
        if let img = _groundNormal { return img }
        let img = groundDetailNormalImage(size: size, strength: strength)
        _groundNormal = img
        return img
    }

    private static func groundDetailNormalImage(size: Int, strength: Double) -> UIImage {
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
        let s = max(0.001, strength)

        func h(_ x: Int, _ y: Int) -> Double {
            let xx = (x % W + W) % W
            let yy = (y % H + H) % H
            let v = Double(map.value(at: vector_int2(Int32(xx), Int32(yy))))
            return (v * 0.5 + 0.5)
        }

        for y in 0..<H {
            for x in 0..<W {
                let hx1 = h(x + 1, y), hx0 = h(x - 1, y)
                let hy1 = h(x, y + 1), hy0 = h(x, y - 1)
                let dx = (hx1 - hx0) * s
                let dy = (hy1 - hy0) * s
                let n = simd_normalize(simd_float3(Float(-dx), Float(-dy), 1.0))
                let r = UInt8((n.x * 0.5 + 0.5) * 255)
                let g = UInt8((n.y * 0.5 + 0.5) * 255)
                let b = UInt8((n.z * 0.5 + 0.5) * 255)
                let idx = y * bpr + x * 4
                bytes[idx + 0] = r
                bytes[idx + 1] = g
                bytes[idx + 2] = b
                bytes[idx + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = bytes
        let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
