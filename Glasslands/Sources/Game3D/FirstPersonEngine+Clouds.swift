//
//  FirstPersonEngine+Clouds.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cloud impostors (SceneKit shader-modifier path) + maintenance utilities.
//  Changes:
//   - Removed reliance on SCNBillboardConstraint. We orient cluster groups  manually each frame.
//   - Orientation is robust near the zenith to avoid GPU/driver stalls.
//   - Materials, lighting and advection behaviour unchanged.
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

    // MARK: - Volumetric cloud impostors (shader-modifier path)

    @MainActor
    func enableVolumetricCloudImpostors(_ on: Bool) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        // Strip any legacy SCNBillboardConstraint from cluster groups (safety).
        layer.childNodes.forEach { $0.constraints = [] }

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            if on {
                // Determine half-size in world units so shader can keep UVs aspect-correct
                let (hx, hy): (CGFloat, CGFloat) = {
                    if let p = g as? SCNPlane {
                        return (max(0.001, p.width * 0.5), max(0.001, p.height * 0.5))
                    } else {
                        let bb = g.boundingBox
                        let w = CGFloat(max(0.001, (bb.max.x - bb.min.x) * 0.5))
                        let h = CGFloat(max(0.001, (bb.max.y - bb.min.y) * 0.5))
                        return (w, h)
                    }
                }()

                let m = CloudImpostorProgram.makeMaterial(halfWidth: hx, halfHeight: hy)

                // Preserve any sprite tint/transparency if present so look stays consistent.
                if let old = g.firstMaterial {
                    m.multiply.contents = old.multiply.contents
                    m.transparency = old.transparency
                }
                g.firstMaterial = m
            } else {
                // Back to plain billboards
                for m in g.materials {
                    m.shaderModifiers = nil
                    m.program = nil
                }
            }
        }

        // **Important**: the billboard layer is created asynchronously.
        // After swapping materials in, push the sun direction + tuned params now.
        if on { applyCloudSunUniforms() }
    }

    // MARK: - Disabled prewarm (no-op to avoid SceneKit assertion on iOS 26)

    @MainActor
    func prewarmCloudImpostorPipelines() {
        // Intentionally left empty. Avoids calling SCNRenderer.prepare(...) on SCNProgram-backed materials.
    }

    // MARK: - Per-frame uniforms + impostor advection (renderer thread → MainActor)
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        // Keep the sky anchor co-located with the player so large radii remain stable.
        if skyAnchor.parent == scene.rootNode {
            skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition
        }

        // One-time ring radii bootstrap (as in your current code)
        if cloudRMax <= 1.0 || cloudRMax < cloudRMin + 10.0 {
            let R = Float(cfg.skyDistance)
            let rNearMax: Float = max(560, R * 0.22)
            let rNearHole: Float = rNearMax * 0.34
            let rBridge0: Float = rNearMax * 1.06
            let rBridge1: Float = rBridge0 + max(900, R * 0.42)
            let rMid0: Float = rBridge1 - 100
            let rMid1: Float = rMid0 + max(2100, R * 1.05)
            let rFar0: Float = rMid1 + max(650, R * 0.34)
            let rFar1: Float = rFar0 + max(3000, R * 1.40)
            let rUltra0: Float = rFar1 + max(700, R * 0.40)
            let rUltra1: Float = rUltra0 + max(1600, R * 0.60)
            cloudRMin = rNearHole
            cloudRMax = rUltra1
            _ = (rBridge0, rBridge1, rMid0, rMid1, rFar0, rFar1, rUltra0) // silence
        }

        // Update shared volumetric uniforms from render clock.
        VolCloudUniformsStore.shared.update(
            time: Float(t),
            sunDirWorld: simd_normalize(sunDirWorld),
            wind: cloudWind,
            domainOffset: cloudDomainOffset
        )

        // Advection (small step with stable speed mapping)
        let dt: Float = 1.0 / 60.0
        advectAllCloudBillboards(dt: dt)

        // Manual billboard facing (fixed orientation)
        orientAllCloudGroupsTowardCamera()

        // NEW: apply zenith guard with gentle hysteresis (depth read off near straight-up only).
        // This leverages the helper defined in FirstPersonEngine+ZenithCull.swift.
        // The 'hide' path now triggers only extremely close to 90° to preserve visuals.
        updateZenithCull(
            depthOffEnter: 1.05, // ~60°
            depthOffExit:  0.95, // ~54°
            hideEnterRad:  1.50, // ~86° (very rare)
            hideExitRad:   1.44  // ~82.5°
        )
    }

    // MARK: - Billboard advection (renderer thread → MainActor)

    private func advectAllCloudBillboards(dt: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        @inline(__always)
        func windLocal(_ w: simd_float2, _ yaw: Float) -> simd_float2 {
            let c = cosf(yaw), s = sinf(yaw)
            return simd_float2(w.x * c + w.y * s, -w.x * s + w.y * c)
        }

        let wL = windLocal(cloudWind, layer.presentation.eulerAngles.y)
        let wLen = simd_length(wL)
        let wDir = (wLen < 1e-6) ? simd_float2(1, 0) : (wL / wLen)

        let Rmin: Float = cloudRMin
        let Rmax: Float = cloudRMax
        let Rref: Float = max(1, Rmin + 0.85 * (Rmax - Rmin))
        let vSpinRef: Float = cloudSpinRate * Rref

        let wRef: Float = 0.6324555
        let windMul = simd_clamp(wLen / max(1e-5, wRef), 0.12, 0.90)
        let advectionGain: Float = 0.35
        let baseSpeedUnits: Float = vSpinRef * windMul * advectionGain

        let span: Float = max(1e-5, Rmax - Rmin)
        let wrapLen: Float = (2 * Rmax) + 0.20 * span
        let wrapCap: Float = Rmax + 0.10 * span

        // Prefer groups: a group has puff children (SCNPlane geometries).
        var groups: [SCNNode] = []
        var orphans: [SCNNode] = []

        for child in layer.childNodes {
            var hasPuffs = false
            for bb in child.childNodes {
                if bb.geometry is SCNPlane { hasPuffs = true; break }
            }
            if hasPuffs {
                groups.append(child)
            } else {
                // Treat bare sprites as "orphans" (rare).
                if child.geometry is SCNPlane { orphans.append(child) }
            }
        }

        if !groups.isEmpty {
            for g in groups {
                advectCluster(
                    group: g,
                    dir: wDir,
                    baseV: baseSpeedUnits,
                    dt: dt,
                    Rmin: Rmin,
                    Rmax: Rmax,
                    span: span,
                    wrapCap: wrapCap,
                    wrapLen: wrapLen,
                    calmSpin: (wLen < 1e-4)
                )
            }
        } else {
            // Fallback: layer with only sprites
            layer.enumerateChildNodes { node, _ in
                guard node.geometry is SCNPlane else { return }
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

    private func advectCluster(
        group: SCNNode,
        dir: simd_float2,
        baseV: Float,
        dt: Float,
        Rmin: Float,
        Rmax: Float,
        span: Float,
        wrapCap: Float,
        wrapLen: Float,
        calmSpin: Bool
    ) {
        let gid = ObjectIdentifier(group)
        // Compute + cache centroid from puff children (by geometry, not constraint).
        let c0: simd_float3 = {
            if let cached = cloudClusterCentroidLocal[gid] { return cached }
            var sum = simd_float3.zero
            var n = 0
            for bb in group.childNodes {
                if bb.geometry is SCNPlane {
                    sum += bb.simdPosition; n += 1
                }
            }
            let c = (n > 0) ? (sum / Float(n)) : .zero
            cloudClusterCentroidLocal[gid] = c
            return c
        }()

        let cw = c0 + group.simdPosition
        let r = simd_length(SIMD2(cw.x, cw.z))
        let tR = simd_clamp((r - Rmin) / span, 0, 1)

        // Parallax curve (near moves faster, far slower)
        let p: Float = 2.4
        let nearFactor: Float = 0.85
        let farFactor: Float = 0.06
        let tEase = powf(tR, p)
        let parallax: Float = nearFactor + (farFactor - nearFactor) * tEase

        if calmSpin {
            // Tiny spin to keep motion in calm wind
            let theta = cloudSpinRate * dt * parallax
            let ca = cosf(theta), sa = sinf(theta)
            let vx = cw.x, vz = cw.z
            let rx = vx * ca - vz * sa
            let rz = vx * sa + vz * ca
            group.simdPosition.x = rx - c0.x
            group.simdPosition.z = rz - c0.z
            return
        }

        // Advect along wind axis, recycle at far rim.
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

    // MARK: - NEW: robust manual billboard orientation (no SCNBillboardConstraint)
    @MainActor
    private func orientAllCloudGroupsTowardCamera() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        // Presentation POV for smooth motion
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition
        let worldUp = simd_float3(0, 1, 0)

        for g in layer.childNodes {
            // Ensure no legacy constraints remain.
            if let cs = g.constraints, !cs.isEmpty { g.constraints = [] }

            let gp = g.presentation.simdWorldPosition

            var forward = camPos - gp // object -> camera
            let len2 = simd_length_squared(forward)
            if len2 < 1e-12 || !forward.x.isFinite || !forward.y.isFinite || !forward.z.isFinite {
                continue
            }
            forward /= sqrt(len2)

            // Right = up × forward (robust when forward ≈ up)
            var right = simd_cross(worldUp, forward)
            if simd_length_squared(right) < 1e-8 {
                // Camera is almost vertical; pick a stable fallback right.
                right = simd_float3(1, 0, 0)
            } else {
                right = simd_normalize(right)
            }

            // Orthonormal up so that right × up = forward
            let up = simd_normalize(simd_cross(forward, right))

            // Column-major basis: [right, up, forward]  ← (was -forward causing culled faces)
            let basis = simd_float3x3(columns: (right, up, forward))
            let q = simd_quaternion(basis)
            g.simdOrientation = q
        }
    }

    // MARK: - Material maintenance / diagnostics (unchanged)

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

        @inline(__always)
        func hasValidDiffuse(_ contents: Any?) -> Bool {
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
        if rebound > 0 { print("[Clouds] rebound diffuse on \(rebound) puff materials") }
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
        layer.enumerateChildNodes { _, _ in geoms += 1 }
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

    @MainActor
    func removeCloudBillboards() {
        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            layer.removeFromParentNode()
        }
        cloudLayerNode = nil
        cloudBillboardNodes.removeAll()
        cloudClusterGroups.removeAll()
        cloudClusterCentroidLocal.removeAll()
    }

    @MainActor
    func removeVolumetricDomeIfPresent() {
        skyAnchor.childNodes
            .filter { $0.name == "VolumetricCloudLayer" }
            .forEach { $0.removeFromParentNode() }
    }
}
