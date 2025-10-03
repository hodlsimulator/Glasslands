//
//  CloudDome+Async.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Off-main orchestration; compute is routed through MainActor the same way
//  we did in c77df77 to avoid the compiler’s global-actor inference traps.
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
            // Important: run compute via MainActor (c77df77 workaround).
            let px = await MainActor.run {
                computeCumulusPixels(
                    width: width,
                    height: height,
                    coverage: coverage,
                    edgeSoftness: edgeSoftness,
                    seed: seed,
                    sunAzimuthDeg: sunAzimuthDeg,
                    sunElevationDeg: sunElevationDeg
                )
            }
            await MainActor.run {
                let node = buildDomeNode(radius: radius, pixels: px)
                completion(node)
            }
        }
    }

    // Async/await variant.
    nonisolated static func makeNode(
        radius: CGFloat,
        coverage: Float = 0.34,
        edgeSoftness: Float = 0.20,
        seed: UInt32 = 424242,
        width: Int = 1280,
        height: Int = 640,
        sunAzimuthDeg: Float = 35,
        sunElevationDeg: Float = 63
    ) async -> SCNNode {
        // Same c77df77 pattern.
        let px = await MainActor.run {
            computeCumulusPixels(
                width: width,
                height: height,
                coverage: coverage,
                edgeSoftness: edgeSoftness,
                seed: seed,
                sunAzimuthDeg: sunAzimuthDeg,
                sunElevationDeg: sunElevationDeg
            )
        }
        return await MainActor.run { buildDomeNode(radius: radius, pixels: px) }
    }

    @MainActor
    private static func buildDomeNode(radius: CGFloat, pixels: CumulusPixels) -> SCNNode {
        let bytesPerRow = pixels.width * 4
        let data = Data(pixels.rgba) as CFData
        let provider = CGDataProvider(data: data)!
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cgImage = CGImage(
            width: pixels.width,
            height: pixels.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        let skyImage = UIImage(cgImage: cgImage)
        return CloudDome.make(radius: radius, skyImage: skyImage)
    }
}
