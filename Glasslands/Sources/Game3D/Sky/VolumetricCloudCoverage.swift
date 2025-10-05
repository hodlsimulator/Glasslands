//
//  VolumetricCloudCoverage.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Builds a grayscale equirect coverage texture from the same
//  impostor logic as the billboard sprites (pile-of-balls clusters).
//  This is sampled in the volumetric shader for base density.
//

import UIKit
import CoreGraphics
import simd

enum VolumetricCloudCoverage {
    struct Options {
        var width: Int = 768
        var height: Int = 384
        var coverage: Float = 0.38      // 0…1
        var seed: UInt32 = 424242
        var zenithCapScale: Float = 0.35
    }

    @MainActor
    static func makeImage(_ opts: Options = Options()) -> UIImage {
        let W = max(256, opts.width)
        let H = max(128, opts.height)

        // Build base fields in the same style as the billboard impostors.
        let FW = max(256, W / 2)
        let FH = max(128, H / 2)
        let base = CloudFieldLL.build(width: FW, height: FH, coverage: opts.coverage, seed: opts.seed)
        let cap  = ZenithCapField.build(size: max(FW, FH), seed: opts.seed, densityScale: max(0, opts.zenithCapScale))

        // Compose to final resolution.
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        let invW: Float = 1.0 / Float(W)
        let invH: Float = 1.0 / Float(H)

        for j in 0..<H {
            for i in 0..<W {
                let u = (Float(i) + 0.5) * invW
                let v = (Float(j) + 0.5) * invH

                // World direction from equirect UV (matches CumulusRenderer).
                let az = (u - 0.5) * (2.0 * .pi)
                let el = .pi * (0.5 - v)
                let d  = simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))

                let dLL  = base.sample(u: u, v: v)
                // Very gentle zenith cap mixed in only near straight-up.
                let capT = SkyMath.smoothstep(0.92, 0.988, d.y)
                let uc   = d.x * 0.5 + 0.5
                let vc   = d.z * 0.5 + 0.5
                let dCap = cap.sample(u: uc, v: vc) * capT

                let density = max(0, min(1, dLL + dCap))
                let k = (j * W + i) * 4
                let g = UInt8(density * 255.0 + 0.5)
                buf[k + 0] = g
                buf[k + 1] = g
                buf[k + 2] = g
                buf[k + 3] = g // keep alpha == value (handy for debugging)
            }
        }

        let bpr = W * 4
        let data = CFDataCreate(nil, buf, buf.count)!
        let provider = CGDataProvider(data: data)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cg = CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg)
    }
}
