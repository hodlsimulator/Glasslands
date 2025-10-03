//
//  CloudDome+Async.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Off‑main orchestration for the equirect sky. Compute is routed through the
//  main actor so UIKit/CG calls stay safe.
//

@preconcurrency import SceneKit
import UIKit
import CoreGraphics

extension CloudDome {

    // Callback style.
    nonisolated static func makeAsync(
        radius: CGFloat,
        coverage: Float = 0.34,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        width: Int = 1280,
        height: Int = 640,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63,
        completion: @MainActor @escaping (SCNNode) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // Replace with any preferred pixel generator if desired.
            let px = await MainActor.run {
                computeCumulusPixels(
                    width: width, height: height,
                    coverage: coverage, edgeSoftness: edgeSoftness,
                    seed: seed,
                    sunAzimuthDeg: sunAzimuthDeg, sunElevationDeg: sunElevationDeg
                )
            }

            await MainActor.run {
                let bytesPerRow = px.width * 4
                let data = Data(px.rgba) as CFData
                let provider = CGDataProvider(data: data)!
                let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let cg = CGImage(
                    width: px.width, height: px.height,
                    bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: bytesPerRow,
                    space: cs,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                )!
                completion(CloudDome.make(radius: radius, skyImage: UIImage(cgImage: cg)))
            }
        }
    }
}
