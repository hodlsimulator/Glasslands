//
//  FirstPersonEngine+Clouds.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

//  FirstPersonEngine+Clouds.swift
//  Glasslands

import SceneKit
import simd
import UIKit
import CoreGraphics

extension FirstPersonEngine {

    // MARK: - Volumetric cloud impostors

    @MainActor
    func enableVolumetricCloudImpostors(
        _ on: Bool,
        vapour: CGFloat = 3.2,
        coverage: CGFloat = 0.42,
        horizonLift: CGFloat = 0.14
    ) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        let fragment: String? = on ? {
            let mat = CloudBillboardMaterial.makeVolumetricImpostor()
            let frag = mat.shaderModifiers?[.fragment] ?? ""
            return CloudBillboardMaterial.volumetricMarker + frag
        }() : nil

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let s4 = invView * simd_float4(simd_normalize(sunDirWorld), 0)
        let s = simd_normalize(simd_float3(s4.x, s4.y, s4.z))
        let sunViewV = SCNVector3(s.x, s.y, s.z)
        let tintV = SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z)

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                var mods = m.shaderModifiers ?? [:]
                mods[.fragment] = fragment
                m.shaderModifiers = mods
                if on {
                    m.setValue(sunViewV, forKey: "sunDirView")
                    m.setValue(tintV,    forKey: "sunTint")
                    m.setValue(coverage, forKey: "coverage")
                    m.setValue(vapour,   forKey: "densityMul")   // ← dial this if needed
                    m.setValue(0.95 as CGFloat, forKey: "stepMul")
                    m.setValue(horizonLift,     forKey: "horizonLift")
                }
            }
        }

        if on { prewarmCloudImpostorPipelines() }
    }

    // Called by RendererProxy each frame (keep as-is)
    @MainActor
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        guard
            let sphere = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false)
                ?? scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: false),
            let m = sphere.geometry?.firstMaterial
        else { return }

        m.setValue(CGFloat(t), forKey: "time")

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunDirWorld, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        m.setValue(sunViewV, forKey: "sunDirView")
        m.setValue(SCNVector3(sunDirWorld.x, sunDirWorld.y, sunDirWorld.z), forKey: "sunDirWorld")
        VolumetricCloudProgram.updateUniforms(from: m)
    }

    // MARK: - Material maintenance / diagnostics

    @MainActor
    func forceReplaceAllCloudBillboards() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] forceReplaceAllCloudBillboards: no layer")
            return
        }

        var geometries = 0
        var replaced = 0
        var reboundDiffuse = 0

        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            geometries += 1

            let newM = CloudBillboardMaterial.makeCurrent()

            let old = geo.firstMaterial
            if let ui = old?.diffuse.contents as? UIImage, (ui.cgImage != nil || ui.ciImage != nil) {
                newM.diffuse.contents = ui
            } else if let ci = old?.diffuse.contents as? CIImage {
                newM.diffuse.contents = UIImage(ciImage: ci)
            } else if let color = old?.diffuse.contents as? UIColor {
                newM.diffuse.contents = color
            } else {
                newM.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                reboundDiffuse += 1
            }

            newM.transparency = old?.transparency ?? 1
            newM.multiply.contents = old?.multiply.contents

            geo.firstMaterial?.program = nil
            geo.firstMaterial?.shaderModifiers = nil

            geo.firstMaterial = newM
            replaced += 1
        }

        print("[Clouds] force-replaced materials on \(replaced)/\(geometries) geometry nodes (fallback bound to \(reboundDiffuse))")
    }

    @MainActor
    func sanitizeCloudBillboards() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] no CumulusBillboardLayer found")
            return
        }

        @inline(__always)
        func hasValidDiffuse(_ contents: Any?) -> Bool {
            guard let c = contents else { return false }
            if let ui = c as? UIImage { return ui.cgImage != nil || ui.ciImage != nil }
            if c is UIColor { return true }
            return true
        }

        var fixedDiffuse = 0
        var nukedProgram = 0
        var nukedSamplerBased = 0

        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry, let mat = geo.firstMaterial else { return }

            if mat.program != nil {
                mat.program = nil
                nukedProgram += 1
            }

            if let frag = mat.shaderModifiers?[.fragment],
               frag.contains("texture2d<") || frag.contains("sampler") || frag.contains("u_diffuseTexture") {
                mat.shaderModifiers = nil
                nukedSamplerBased += 1
            }

            if !hasValidDiffuse(mat.diffuse.contents) {
                mat.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                fixedDiffuse += 1
            }
        }

        print("[Clouds] sanitize: fixedDiffuse=\(fixedDiffuse) nukedProgram=\(nukedProgram) nukedSamplerBased=\(nukedSamplerBased)")
    }

    @MainActor
    func rebindMissingCloudTextures() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        @inline(__always)
        func hasValidDiffuse(_ contents: Any?) -> Bool {
            guard let c = contents else { return false }
            if let ui = c as? UIImage { return ui.cgImage != nil || ui.ciImage != nil }
            if c is UIColor { return true }
            return true
        }

        var rebound = 0
        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry, let mat = geo.firstMaterial else { return }
            if !hasValidDiffuse(mat.diffuse.contents) {
                mat.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                rebound += 1
            }
        }

        if rebound > 0 {
            print("[Clouds] rebound diffuse on \(rebound) puff materials")
        }
    }

    @MainActor
    func debugCloudShaderOnce(tag: String) {
        struct Flag { static var logged = false }
        guard !Flag.logged else { return }
        Flag.logged = true

        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[CloudFrag] \(tag): layer not found")
            return
        }

        var geoms = 0, withFrag = 0, withProg = 0, risky = 0

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry, let m = g.firstMaterial else { return }
            geoms += 1

            if let frag = m.shaderModifiers?[.fragment] {
                withFrag += 1
                let len = frag.count
                let usesSampler = frag.contains("texture2d<") || frag.contains("sampler")
                let usesPow = frag.contains("pow(")
                let hasBody = frag.contains("#pragma body")
                print("[CloudFrag] len=\(len) sampler=\(usesSampler) pow=\(usesPow) body=\(hasBody)")
                if usesSampler { risky += 1 }
            }

            if m.program != nil {
                withProg += 1
                print("[CloudFrag] has SCNProgram on node: \(node.name ?? "")")
            }
        }

        print("[CloudFrag] \(tag): geoms=\(geoms) withFrag=\(withFrag) withProg=\(withProg) risky=\(risky)")
    }

    @MainActor
    func forceReplaceAndVerifyClouds() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] verify: no layer")
            return
        }

        let templ = CloudBillboardMaterial.makeCurrent()
        var geoms = 0, replaced = 0, ok = 0, bad = 0

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            geoms += 1

            let m = templ.copy() as! SCNMaterial
            m.diffuse.contents = g.firstMaterial?.diffuse.contents ?? CloudSpriteTexture.fallbackWhite2x2
            g.firstMaterial = m
            replaced += 1

            let frag = m.shaderModifiers?[.fragment] ?? ""
            if frag.contains(CloudBillboardMaterial.volumetricMarker) {
                ok += 1
            } else {
                bad += 1
            }
        }

        print("[Clouds] verify: geoms=\(geoms) replaced=\(replaced) ok=\(ok) bad=\(bad)")
    }
    
    @MainActor
    func prewarmCloudImpostorPipelines() {
        guard let v = scnView,
              let root = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true)
        else { return }

        var seen = Set<ObjectIdentifier>()
        root.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                let id = ObjectIdentifier(m)
                if seen.insert(id).inserted {
                    _ = v.prepare(m, shouldAbortBlock: nil)   // prepare each material individually
                }
            }
        }
    }
}
