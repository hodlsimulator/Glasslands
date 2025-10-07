//
//  FirstPersonEngine+Clouds.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

import SceneKit
import simd
import UIKit
import CoreGraphics

@MainActor
private enum AdvectClock {
    static var last: TimeInterval = 0
}

extension FirstPersonEngine {

    // MARK: - Volumetric cloud impostors
    @MainActor
    func enableVolumetricCloudImpostors(
        _ on: Bool,
        vapour: CGFloat = 3.2,
        coverage: CGFloat = 0.42,
        horizonLift: CGFloat = 0.14
    ) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

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
        let tintV   = SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z)

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                var mods = m.shaderModifiers ?? [:]
                mods[.fragment] = fragment
                m.shaderModifiers = mods
                if on {
                    m.setValue(sunViewV, forKey: "sunDirView")
                    m.setValue(tintV,   forKey: "sunTint")
                    m.setValue(coverage, forKey: "coverage")
                    m.setValue(vapour,   forKey: "densityMul")
                    m.setValue(0.95 as CGFloat, forKey: "stepMul")
                    m.setValue(horizonLift, forKey: "horizonLift")
                }
            }
        }

        if on { prewarmCloudImpostorPipelines() }
    }

    // Called by RendererProxy each frame
    @MainActor
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        if skyAnchor.parent == scene.rootNode {
            skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition
        }

        if cloudRMax <= 1.0 || cloudRMax < cloudRMin + 10.0 {
            let R = Float(cfg.skyDistance)
            let rNearMax : Float = max(560, R * 0.22)
            let rNearHole: Float = rNearMax * 0.34
            let rBridge0 : Float = rNearMax * 1.06
            let rBridge1 : Float = rBridge0 + max(900, R * 0.42)
            let rMid0 : Float = rBridge1 - 100
            let rMid1 : Float = rMid0 + max(2100, R * 1.05)
            let rFar0 : Float = rMid1 + max(650, R * 0.34)
            let rFar1 : Float = rFar0 + max(3000, R * 1.40)
            let rUltra0 : Float = rFar1 + max(700, R * 0.40)
            let rUltra1 : Float = rUltra0 + max(1600, R * 0.60)
            cloudRMin = rNearHole
            cloudRMax = rUltra1
            _ = (rBridge0, rBridge1, rMid0, rMid1, rFar0, rFar1)
        }

        let sunW = simd_normalize(sunDirWorld)
        VolCloudUniformsStore.shared.update(
            time: Float(t),
            sunDirWorld: sunW,
            wind: cloudWind,
            domainOffset: cloudDomainOffset,
            domainRotate: 0,
            baseY: 400, topY: 1400,
            coverage: 0.50,
            densityMul: 1.15,
            stepMul: 0.85,
            mieG: 0.60,
            powderK: 2.10,
            horizonLift: 0.14,
            detailMul: 1.10,
            puffScale: 0.0045,
            puffStrength: 0.65
        )

        let rawDt: TimeInterval = (AdvectClock.last == 0) ? (1.0/60.0) : max(0, t - AdvectClock.last)
        AdvectClock.last = t
        let dt: Float = Float(min(1.0/30.0, max(1.0/180.0, rawDt)))
        advectAllCloudBillboards(dt: dt)
    }


    // MARK: - Billboard advection (covers every possible parentage)
    @MainActor
    private func advectAllCloudBillboards(dt: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        @inline(__always)
        func windLocal(_ w: simd_float2, _ yaw: Float) -> simd_float2 {
            let c = cosf(yaw), s = sinf(yaw)
            return simd_float2(w.x * c + w.y * s, -w.x * s + w.y * c)
        }

        let wL   = windLocal(cloudWind, layer.presentation.eulerAngles.y)
        let wLen = simd_length(wL)
        let wDir = (wLen < 1e-6) ? simd_float2(1, 0) : (wL / wLen)

        // Reference spin speed from the original far belt
        let Rmin: Float = cloudRMin
        let Rmax: Float = cloudRMax
        let Rref: Float = max(1, Rmin + 0.85 * (Rmax - Rmin))
        let vSpinRef: Float = cloudSpinRate * Rref

        // Global slowdown + tighter wind clamp (much gentler overall)
        let wRef: Float = 0.6324555
        let windMul     = simd_clamp(wLen / max(1e-5, wRef), 0.12, 0.90)
        let advectionGain: Float = 0.35
        let baseSpeedUnits: Float = vSpinRef * windMul * advectionGain

        let span: Float    = max(1e-5, Rmax - Rmin)
        let wrapLen: Float = (2 * Rmax) + 0.20 * span
        let wrapCap: Float = Rmax + 0.10 * span

        var groups: [SCNNode] = []
        var orphans: [SCNNode] = []

        for child in layer.childNodes {
            var hasPuffs = false
            for bb in child.childNodes {
                if let cs = bb.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                    hasPuffs = true; break
                }
            }
            if hasPuffs {
                groups.append(child)
            } else if let cs = child.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                orphans.append(child)
            }
        }

        if !groups.isEmpty {
            for g in groups {
                advectCluster(group: g,
                              dir: wDir,
                              baseV: baseSpeedUnits,
                              dt: dt,
                              Rmin: Rmin,
                              Rmax: Rmax,
                              span: span,
                              wrapCap: wrapCap,
                              wrapLen: wrapLen,
                              calmSpin: (wLen < 1e-4))
            }
        } else {
            layer.enumerateChildNodes { node, _ in
                guard let cs = node.constraints,
                      cs.contains(where: { $0 is SCNBillboardConstraint })
                else { return }
                let d = wDir * (baseSpeedUnits * dt)
                node.simdPosition.x += d.x
                node.simdPosition.z += d.y
            }
        }

        for n in orphans {
            let d = wDir * (baseSpeedUnits * dt)
            n.simdPosition.x += d.x
            n.simdPosition.z += d.y
        }
    }

    @MainActor
    private func advectCluster(group: SCNNode,
                               dir: simd_float2,
                               baseV: Float,
                               dt: Float,
                               Rmin: Float,
                               Rmax: Float,
                               span: Float,
                               wrapCap: Float,
                               wrapLen: Float,
                               calmSpin: Bool) {

        let gid = ObjectIdentifier(group)
        let c0: simd_float3 = {
            if let cached = cloudClusterCentroidLocal[gid] { return cached }
            var sum = simd_float3.zero
            var n = 0
            for bb in group.childNodes {
                if let cs = bb.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                    sum += bb.simdPosition; n += 1
                }
            }
            let c = (n > 0) ? (sum / Float(n)) : .zero
            cloudClusterCentroidLocal[gid] = c
            return c
        }()

        let cw = c0 + group.simdPosition

        // Stronger near/far split: overhead ≈ 85% of base, far horizon ≈ 6% of base.
        // Smooth ease-out towards the horizon so distant clouds barely creep.
        let r   = simd_length(SIMD2(cw.x, cw.z))
        let tR  = simd_clamp((r - Rmin) / span, 0, 1)
        let p: Float = 2.4
        let nearFactor: Float = 0.85
        let farFactor:  Float = 0.06
        let tEase = powf(tR, p)
        let parallax: Float = nearFactor + (farFactor - nearFactor) * tEase

        if calmSpin {
            let theta = cloudSpinRate * dt * parallax
            let ca = cosf(theta), sa = sinf(theta)
            let vx = cw.x, vz = cw.z
            let rx = vx * ca - vz * sa
            let rz = vx * sa + vz * ca
            group.simdPosition.x = rx - c0.x
            group.simdPosition.z = rz - c0.z
            return
        }

        let v = baseV * parallax
        let d = dir * (v * dt)
        group.simdPosition.x += d.x
        group.simdPosition.z += d.y

        let ax = simd_dot(SIMD2(cw.x, cw.z), dir)
        if ax > wrapCap {
            group.simdPosition.x -= dir.x * wrapLen
            group.simdPosition.z -= dir.y * wrapLen
        } else if ax < -wrapCap {
            group.simdPosition.x += dir.x * wrapLen
            group.simdPosition.z += dir.y * wrapLen
        }
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
            print("[Clouds] no CumulusBillboardLayer found"); return
        }
        @inline(__always) func hasValidDiffuse(_ contents: Any?) -> Bool {
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
            if mat.program != nil { mat.program = nil; nukedProgram += 1 }
            if let frag = mat.shaderModifiers?[.fragment],
               frag.contains("texture2d<") || frag.contains("sampler") || frag.contains("u_diffuseTexture") {
                mat.shaderModifiers = nil; nukedSamplerBased += 1
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
        @inline(__always) func hasValidDiffuse(_ contents: Any?) -> Bool {
            guard let c = contents else { return false }
            if let ui = c as? UIImage { return ui.cgImage != nil || ui.ciImage != nil }
            if c is UIColor { return true }
            return false
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
            print("[CloudFrag] \(tag): layer not found"); return
        }

        var geoms = 0, withFrag = 0, withProg = 0, risky = 0
        layer.enumerateChildNodes { _, _ in
            geoms += 1
        }
        print("[CloudFrag] \(tag): geoms=\(geoms) withFrag=\(withFrag) withProg=\(withProg) risky=\(risky)")
    }

    @MainActor
    func forceReplaceAndVerifyClouds() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] verify: no layer"); return
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
            if frag.contains(CloudBillboardMaterial.volumetricMarker) { ok += 1 } else { bad += 1 }
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
                    _ = v.prepare(m, shouldAbortBlock: nil)
                }
            }
        }
    }
    
    @MainActor
    func installVolumetricCloudsIfMissing(
        baseY: CGFloat = 400,
        topY: CGFloat = 1400,
        coverage: CGFloat = 0.46
    ) {
        if skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false) == nil {
            let r = CGFloat(cfg.skyDistance)
            let n = VolumetricCloudLayer.make(radius: r, baseY: baseY, topY: topY, coverage: coverage)
            skyAnchor.addChildNode(n)
        }
        // Prefer the true volumetric layer; disable impostor billboards.
        enableVolumetricCloudImpostors(false)
    }
}
