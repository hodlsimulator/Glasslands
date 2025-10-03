//
//  ImageCreatorService.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import UIKit
import CoreGraphics
import Metal
import MetalKit

#if canImport(ImagePlayground)
import ImagePlayground  // Hypothetical iOS 26 framework (guarded)
#endif

/// Builds a stylised "postcard" image.
/// If Image Playground / Image Creator is present, wire it here; otherwise we
/// render a high-quality CoreGraphics card and optionally apply a small Metal compute effect.
final class ImageCreatorService {

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var ciContext: CIContext? = {
        guard let device else { return nil }
        return CIContext(mtlDevice: device)
    }()

    func generatePostcard(from snapshot: UIImage, title: String, palette: [UIColor]) async throws -> UIImage {
        #if canImport(ImagePlayground)
        if #available(iOS 26.0, *) {
            // Integrate Image Playground/Image Creator here if desired.
            // For now we proceed with our high-quality fallback posterization.
        }
        #endif

        // 1) Compose postcard with frame + palette swatches + title
        let composed = compose(snapshot: snapshot, title: title, palette: palette)

        // 2) Optional Metal "glass tint" compute pass (from TerrainShaders.metal)
        if let processed = try? metalTint(image: composed) {
            return processed
        } else {
            return composed
        }
    }

    // MARK: - CoreGraphics composition
    private func compose(snapshot: UIImage, title: String, palette: [UIColor]) -> UIImage {
        let cardSize = CGSize(width: 1080, height: 1350) // 4:5 social-friendly
        let renderer = UIGraphicsImageRenderer(size: cardSize)
        return renderer.image { ctx in
            let ctx = ctx.cgContext

            // Background
            (palette.first ?? .black).withAlphaComponent(0.9).setFill()
            ctx.fill(CGRect(origin: .zero, size: cardSize))

            // Image area
            let inset: CGFloat = 48
            let imageRect = CGRect(x: inset, y: inset*1.25, width: cardSize.width - inset*2, height: cardSize.height * 0.62)
                .integral
            snapshot.draw(in: imageRect)

            // Border
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(6)
            ctx.stroke(imageRect.insetBy(dx: -8, dy: -8))

            // Title
            let titleRect = CGRect(x: inset, y: imageRect.maxY + 28, width: cardSize.width - inset*2, height: 64)
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            (title.uppercased() as NSString).draw(in: titleRect, withAttributes: titleAttr)

            // Palette swatches
            let swatchW: CGFloat = (cardSize.width - inset*2 - 20) / CGFloat(max(1, palette.count))
            let swatchH: CGFloat = 40
            for (i, col) in palette.enumerated() {
                let r = CGRect(x: inset + CGFloat(i) * (swatchW + 4),
                               y: titleRect.maxY + 18,
                               width: swatchW, height: swatchH).integral
                col.setFill()
                ctx.fill(r)
            }

            // Footer
            let footer = "Glasslands — Generated on device"
            let footAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ]
            let footRect = CGRect(x: inset, y: cardSize.height - inset - 24, width: cardSize.width - inset*2, height: 24)
            (footer as NSString).draw(in: footRect, withAttributes: footAttr)
        }
    }

    // MARK: - Metal compute pass
    private func metalTint(image: UIImage) throws -> UIImage {
        guard let device,
              let cg = image.cgImage else { return image }

        let loader = MTKTextureLoader(device: device)
        let texture = try loader.newTexture(cgImage: cg, options: [
            MTKTextureLoader.Option.SRGB: false
        ])

        let lib = try device.makeDefaultLibrary(bundle: .main)
        guard let fn = lib.makeFunction(name: "glassTintKernel") else { return image }
        let pipeline = try device.makeComputePipelineState(function: fn)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                               width: texture.width, height: texture.height,
                                                               mipmapped: false)
        outDesc.usage = [.shaderWrite, .shaderRead]
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return image }

        guard let cmdq = device.makeCommandQueue(), let cmd = cmdq.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return image }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setTexture(outTex, index: 1)

        // Threadgroups
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tgSize = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: texture.width, height: texture.height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Back to UIImage
        let ci = CIImage(mtlTexture: outTex, options: [CIImageOption.colorSpace: CGColorSpaceCreateDeviceRGB()])!
        let ctx = ciContext ?? CIContext()
        let outCG = ctx.createCGImage(ci, from: ci.extent)!
        return UIImage(cgImage: outCG)
    }
}
