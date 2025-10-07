//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Sun control + GPU cloud-shadow texture generation.
//  No modulated projector: ground darkens via a tiny shader-modifier.
//

import SceneKit
import simd
import Metal
import QuartzCore
import UIKit

extension FirstPersonEngine {

    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Cover → brightness envelope
        let cover = measureSunCover()
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // Sun = only illuminant
        sun.intensity = 1500 * max(0.06, E)
        let D = max(0.0, 1.0 - E)
        let pen: CGFloat = 0.35 + (13.0 - 0.35) * D
        sun.shadowRadius = pen
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.65 + 0.2 * D)

        // No sky fill
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            skyFill.intensity = 0
        }

        // Halo
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * D
            halo.isHidden = D <= 1e-3
        }

        ensureCloudShadowComputer()
        updateCloudShadowTextureAndApplyToGround()
    }

    private func measureSunCover() -> (peak: Float, union: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return (0,0) }
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let cam = pov.simdWorldPosition
        let sunW = simd_normalize(sunDirWorld)
        let sunR: Float = degreesToRadians(6.0) * 0.5
        let feather: Float = 0.15 * (.pi / 180.0)
        var peak: Float = 0.0, oneMinus: Float = 1.0

        layer.enumerateChildNodes { node, _ in
            guard let plane = node.geometry as? SCNPlane else { return }
            let pw = node.presentation.simdWorldPosition
            let toP = simd_normalize(pw - cam)
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)
            let dist: Float = simd_length(pw - cam); if dist <= 1e-3 { return }
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist))
            let overlap = (puffR + sunR + feather) - dAngle; if overlap <= 0 { return }
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR))
            t *= angArea
            peak = max(peak, t)
            oneMinus *= max(0.0, 1.0 - min(0.98, t))
        }
        return (peak < 0.01 ? 0 : peak, min(1.0, 1.0 - oneMinus))
    }

    @inline(__always) private func degreesToRadians(_ d: Float) -> Float { d * .pi / 180.0 }
}

// MARK: - Cloud shadow texture (compute) → applied in ground shader

private final class CloudShadowComputer {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private(set) var texture: MTLTexture

    private struct CloudUniforms {
        var sunDirWorld : SIMD4<Float>
        var sunTint     : SIMD4<Float>
        var params0     : SIMD4<Float>
        var params1     : SIMD4<Float>
        var params2     : SIMD4<Float>
        var params3     : SIMD4<Float>
    }
    private struct ShadowUniforms {
        var centerXZ : SIMD2<Float>
        var halfSize : Float
        var pad0     : Float
    }

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let fn  = lib.makeFunction(name: "cloudShadowKernel"),
              let ps  = try? device.makeComputePipelineState(function: fn) else { return nil }
        queue = q; pipeline = ps
        let d = MTLTextureDescriptor()
        d.pixelFormat = .rgba8Unorm; d.width = 768; d.height = 768   // smaller = cheaper
        d.usage = [.shaderWrite, .shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
    }

    func update(using mat: SCNMaterial, sunDir: SIMD3<Float>, centerXZ: SIMD2<Float>, halfSize: Float, time: Float) {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)

        func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        func v3(_ v: Any?) -> SIMD3<Float> {
            if let s = v as? SCNVector3 { return SIMD3(Float(s.x), Float(s.y), Float(s.z)) }
            return .zero
        }
        let wind      = v3(mat.value(forKey: "wind"))
        let baseY     = f(mat.value(forKey: "baseY"))
        let topY      = f(mat.value(forKey: "topY"))
        let coverage  = f(mat.value(forKey: "coverage"))
        let density   = f(mat.value(forKey: "densityMul"))
        let mieG      = f(mat.value(forKey: "mieG"))
        let powderK   = f(mat.value(forKey: "powderK"))
        let horizon   = f(mat.value(forKey: "horizonLift"))
        let detailMul = f(mat.value(forKey: "detailMul"))
        let domOff3   = v3(mat.value(forKey: "domainOffset"))
        let domRot    = f(mat.value(forKey: "domainRotate"))

        var U = CloudUniforms(
            sunDirWorld: SIMD4<Float>(normalize(sunDir), 0),
            sunTint    : SIMD4<Float>(1,1,1,0),
            params0    : SIMD4<Float>( time, wind.x, wind.y, baseY ),
            params1    : SIMD4<Float>( topY, coverage, max(0, density), 1.0 ),
            params2    : SIMD4<Float>( mieG, max(0, powderK), horizon, max(0, detailMul) ),
            params3    : SIMD4<Float>( domOff3.x, domOff3.y, domRot, 0 )
        )
        var SU = ShadowUniforms(centerXZ: centerXZ, halfSize: halfSize, pad0: 0)

        enc.setBytes(&U,  length: MemoryLayout<CloudUniforms>.size, index: 0)
        enc.setBytes(&SU, length: MemoryLayout<ShadowUniforms>.size, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        enc.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding(); cmd.commit()
    }
}

private var _shadowComputer: CloudShadowComputer?

private extension FirstPersonEngine {

    func ensureCloudShadowComputer() {
        if _shadowComputer == nil, let dev = MTLCreateSystemDefaultDevice() {
            _shadowComputer = CloudShadowComputer(device: dev)
        }
    }

    // Small fragment modifier that multiplies ground albedo by cloud shadow
    static let groundShadowFrag: String = """
    #pragma arguments
    texture2d<float> gl_cloudShadowTex;
    float gl_shadowCenterX;
    float gl_shadowCenterZ;
    float gl_shadowHalfSize;
    float gl_shadowStrength;  // 0..1
    #pragma body
    float2 xz = _surface.position.xz;
    float2 uv = float2(
        ( (xz.x - gl_shadowCenterX) / gl_shadowHalfSize ) * 0.5 + 0.5,
        ( (xz.y - gl_shadowCenterZ) / gl_shadowHalfSize ) * 0.5 + 0.5
    );
    if (uv.x>=0.0 && uv.x<=1.0 && uv.y>=0.0 && uv.y<=1.0) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float sh = gl_cloudShadowTex.sample(s, uv).r;      // 1=sun, 0=shadow
        float m = mix(1.0, sh, clamp(gl_shadowStrength,0.0,1.0));
        _output.color.rgb *= m;
    }
    """

    func updateCloudShadowTextureAndApplyToGround() {
        guard let comp = _shadowComputer else { return }

        // Source of cloud params (same as volumetric layer)
        guard let cloudMat = (skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false)
                               ?? scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: false))?
                .geometry?.firstMaterial else { return }

        let pos = (scnView?.pointOfView ?? camNode).presentation.simdWorldPosition
        let centerXZ = SIMD2<Float>(pos.x, pos.z)
        let halfSize: Float = 1000

        comp.update(using: cloudMat,
                    sunDir: sunDirWorld,
                    centerXZ: centerXZ,
                    halfSize: halfSize,
                    time: Float(CACurrentMediaTime()))

        // Apply to every ground material (category 0x0400)
        scene.rootNode.enumerateChildNodes { node, _ in
            guard (node.categoryBitMask & 0x0000_0400) != 0,
                  let g = node.geometry else { return }

            for m in g.materials {
                // Install once
                if m.value(forKey: "GL_shadowInstalled") == nil {
                    var mods = m.shaderModifiers ?? [:]
                    let old = mods[.fragment] ?? ""
                    mods[.fragment] = old + FirstPersonEngine.groundShadowFrag
                    m.shaderModifiers = mods
                    m.setValue(true, forKey: "GL_shadowInstalled")
                    m.setValue(0.85 as CGFloat, forKey: "gl_shadowStrength")
                }
                // Bind texture + mapping
                let mp = (m.value(forKey: "gl_cloudShadowTex") as? SCNMaterialProperty) ?? SCNMaterialProperty(contents: comp.texture)
                mp.contents = comp.texture
                m.setValue(mp, forKey: "gl_cloudShadowTex")
                m.setValue(CGFloat(centerXZ.x), forKey: "gl_shadowCenterX")
                m.setValue(CGFloat(centerXZ.y), forKey: "gl_shadowCenterZ")
                m.setValue(CGFloat(halfSize),   forKey: "gl_shadowHalfSize")
            }
        }
    }
}
