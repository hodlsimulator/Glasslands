//
//  FirstPersonEngine+Sky.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Sun + sky helpers, plus cloud-material uniform updates (billboards + volumetrics).
//  Makes impostors white under sun with no ambient/self-light.
//

import SceneKit
import simd
import UIKit
import CoreGraphics

private struct CloudUniformState {
    let profile: String
    let sunDir: simd_float3
    let densityMul: Float
    let thickness: Float
    let phaseG: Float
    let ambient: Float
    let baseWhite: Float
    let lightGain: Float
    let quality: Float
    let powderK: Float
    let edgeLight: Float
    let backlight: Float
    let edgeFeather: Float
    let heightFade: Float
}

private enum CloudUniformCache {
    static var byEngine: [ObjectIdentifier: CloudUniformState] = [:]
    static var didLogProfile = false
    static var didLogComposite = false
    static var writesSinceReport = 0
    static var updateMsSinceReport: Double = 0
    static var lastPerfLog: CFTimeInterval = CACurrentMediaTime()
}

extension FirstPersonEngine {

    @inline(__always)
    func sunDirection(azimuthDeg: Float, elevationDeg: Float) -> simd_float3 {
        let az = azimuthDeg * .pi / 180
        let el = elevationDeg * .pi / 180
        let x = sinf(az) * cosf(el)
        let y = sinf(el)
        let z = cosf(az) * cosf(el)
        return simd_normalize(simd_float3(x, y, z))
    }

    @MainActor
    func applySunDirection(azimuthDeg: Float, elevationDeg: Float) {
        var dir = sunDirection(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg)

        // Keep the sun on the same “hemisphere” as the current POV so it never flips behind the camera.
        if let pov = (scnView?.pointOfView ?? camNode) as SCNNode? {
            let look = -pov.presentation.simdWorldFront
            if simd_dot(dir, look) < 0 { dir = -dir }
        }

        sunDirWorld = dir

        // Align the scene’s directional lights.
        if let sunLightNode {
            let origin = yawNode.presentation.position
            let incoming = SCNVector3(-dir.x, -dir.y, -dir.z)
            let target = SCNVector3(origin.x + incoming.x, origin.y + incoming.y, origin.z + incoming.z)
            sunLightNode.position = origin
            sunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }

        if let vegSunLightNode {
            let origin = yawNode.presentation.position
            let incoming = SCNVector3(-dir.x, -dir.y, -dir.z)
            let target = SCNVector3(origin.x + incoming.x, origin.y + incoming.y, origin.z + incoming.z)
            vegSunLightNode.position = origin
            vegSunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }

        // Push the HDR sun sprite group out onto the sky dome.
        if let disc = sunDiscNode {
            let dist = CGFloat(cfg.skyDistance)
            disc.simdPosition = simd_float3(dir.x, dir.y, dir.z) * Float(dist)
        }

        // Update sky dome materials (SkyAtmosphere + optional cloud dome shim).
        applySkySunUniforms()

        // Update billboard/impostor materials (fast volumetric puffs).
        applyCloudSunUniforms()
    }

    @MainActor
    private func applySkySunUniforms() {
        let dir = simd_normalize(sunDirWorld)
        let sunW = SCNVector3(dir.x, dir.y, dir.z)
        let tint = SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z)

        if let sky = skyAnchor.childNode(withName: "SkyAtmosphere", recursively: true),
           let m = sky.geometry?.firstMaterial {
            m.setValue(sunW, forKey: "sunDirWorld")
            m.setValue(tint, forKey: "sunTint")
        }

        if let dome = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: true),
           let m = dome.geometry?.firstMaterial {
            m.setValue(sunW, forKey: "sunDirWorld")
            m.setValue(tint, forKey: "sunTint")
        }
    }

    @MainActor
    func applyCloudSunUniforms() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return
        }

        let sunDir = simd_normalize(sunDirWorld)

        // Default profile is "good" (717da10 look). Set CLOUD_PROFILE=current to compare.
        let densityMul: Float = useGoodProfile ? 0.94 : 0.98
        let thickness: Float = useGoodProfile ? 4.5 : 4.5
        let phaseG: Float = useGoodProfile ? 0.52 : 0.58
        let ambient: Float = useGoodProfile ? 0.52 : 0.28
        let baseWhite: Float = useGoodProfile ? 1.08 : 1.0
        let lightGain: Float = useGoodProfile ? 2.25 : 3.0
        let quality: Float = useGoodProfile ? 0.28 : 0.24

        let powderK: Float = useGoodProfile ? 0.60 : 0.70
        let edgeLight: Float = useGoodProfile ? 1.60 : 2.4
        let backlight: Float = Float(cloudSunBacklight)

        let edgeFeather: Float = useGoodProfile ? 0.34 : 0.30
        let heightFade: Float = useGoodProfile ? 0.30 : 0.30

        let state = CloudUniformState(
            profile: useGoodProfile ? "good" : "current",
            sunDir: sunDir,
            densityMul: densityMul,
            thickness: thickness,
            phaseG: phaseG,
            ambient: ambient,
            baseWhite: baseWhite,
            lightGain: lightGain,
            quality: quality,
            powderK: powderK,
            edgeLight: edgeLight,
            backlight: backlight,
            edgeFeather: edgeFeather,
            heightFade: heightFade
        )

        if ProcessInfo.processInfo.environment["CLOUD_DIAG"] == "1", !CloudUniformCache.didLogProfile {
            CloudUniformCache.didLogProfile = true
            print("[CLOUD_DIAG] cloudProfile=\(state.profile) densityMul=\(densityMul) thickness=\(thickness) phaseG=\(phaseG) ambient=\(ambient) baseWhite=\(baseWhite) lightGain=\(lightGain) quality=\(quality) powderK=\(powderK) edgeLight=\(edgeLight) backlight=\(backlight) edgeFeather=\(edgeFeather) heightFade=\(heightFade)")
        }

        let engineID = ObjectIdentifier(self)
        if let last = CloudUniformCache.byEngine[engineID],
           last.profile == state.profile,
           simd_distance(last.sunDir, state.sunDir) < 0.0005,
           abs(last.densityMul - state.densityMul) < 0.0005,
           abs(last.thickness - state.thickness) < 0.0005,
           abs(last.phaseG - state.phaseG) < 0.0005,
           abs(last.ambient - state.ambient) < 0.0005,
           abs(last.baseWhite - state.baseWhite) < 0.0005,
           abs(last.lightGain - state.lightGain) < 0.0005,
           abs(last.quality - state.quality) < 0.0005,
           abs(last.powderK - state.powderK) < 0.0005,
           abs(last.edgeLight - state.edgeLight) < 0.0005,
           abs(last.backlight - state.backlight) < 0.0005,
           abs(last.edgeFeather - state.edgeFeather) < 0.0005,
           abs(last.heightFade - state.heightFade) < 0.0005 {
            return
        }

        CloudUniformCache.byEngine[engineID] = state

        let updateStart = CACurrentMediaTime()
        var uniformWrites = 0

        layer.enumerateChildNodes { node, _ in
            guard let plane = node.geometry as? SCNPlane, let mat = plane.firstMaterial else { return }

            // Clouds are a sky element and always sit behind terrain. Rendering them before the world (and
            // with depth reads disabled) avoids the tile-resolve stalls that show up as "lag" on iOS GPUs.
            // Terrain (opaque) will overwrite them later in the frame.
            node.renderingOrder = -15_000
            mat.readsFromDepthBuffer = false
            mat.writesToDepthBuffer = false

            // Keep blend/dither mode as configured by CloudImpostorProgram.makeMaterial(...).
            // Forcing blended alpha here reintroduces the magenta/pink artefacts.
            mat.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: CloudImpostorProgram.kSunDir)
            uniformWrites += 1
            mat.setValue(NSNumber(value: densityMul), forKey: CloudImpostorProgram.kDensityMul)
            uniformWrites += 1
            mat.setValue(NSNumber(value: thickness), forKey: CloudImpostorProgram.kThickness)
            uniformWrites += 1

            mat.setValue(NSNumber(value: phaseG), forKey: CloudImpostorProgram.kPhaseG)
            uniformWrites += 1
            mat.setValue(NSNumber(value: ambient), forKey: CloudImpostorProgram.kAmbient)
            uniformWrites += 1
            mat.setValue(NSNumber(value: baseWhite), forKey: CloudImpostorProgram.kBaseWhite)
            uniformWrites += 1
            mat.setValue(NSNumber(value: lightGain), forKey: CloudImpostorProgram.kLightGain)
            uniformWrites += 1
            mat.setValue(NSNumber(value: quality), forKey: CloudImpostorProgram.kQuality)
            uniformWrites += 1

            mat.setValue(NSNumber(value: powderK), forKey: CloudImpostorProgram.kPowderK)
            uniformWrites += 1
            mat.setValue(NSNumber(value: edgeLight), forKey: CloudImpostorProgram.kEdgeLight)
            uniformWrites += 1
            mat.setValue(NSNumber(value: backlight), forKey: CloudImpostorProgram.kBacklight)
            uniformWrites += 1
            mat.setValue(NSNumber(value: edgeFeather), forKey: CloudImpostorProgram.kEdgeFeather)
            uniformWrites += 1
            mat.setValue(NSNumber(value: heightFade), forKey: CloudImpostorProgram.kHeightFade)
            uniformWrites += 1

            if ProcessInfo.processInfo.environment["CLOUD_DIAG"] == "1", !CloudUniformCache.didLogComposite {
                CloudUniformCache.didLogComposite = true
                let composite = ProcessInfo.processInfo.environment["CLOUD_COMPOSITE"]?.lowercased() ?? "blend(default)"
                let premulAlpha = (mat.transparencyMode == .aOne)
                print("[CLOUD_DIAG] composite=\(composite) blendMode=\(mat.blendMode.rawValue) depthWrite=\(mat.writesToDepthBuffer) premulAlpha=\(premulAlpha)")
            }
        }

        let updateMs = (CACurrentMediaTime() - updateStart) * 1000.0
        if ProcessInfo.processInfo.environment["CLOUD_DIAG"] == "1" {
            CloudUniformCache.writesSinceReport += uniformWrites
            CloudUniformCache.updateMsSinceReport += updateMs
            let now = CACurrentMediaTime()
            let dt = now - CloudUniformCache.lastPerfLog
            if dt >= 1.0 {
                let wps = Double(CloudUniformCache.writesSinceReport) / dt
                let avgMs = CloudUniformCache.updateMsSinceReport / dt
                print("[CLOUD_DIAG] uniformWritesPerSec=\(String(format: "%.1f", wps)) cloudUpdateMs=\(String(format: "%.3f", avgMs))")
                CloudUniformCache.writesSinceReport = 0
                CloudUniformCache.updateMsSinceReport = 0
                CloudUniformCache.lastPerfLog = now
            }
        }
    }

    // MARK: - HDR sun sprites

    @MainActor
    func makeHDRSunNode(
        coreAngularSizeDeg: CGFloat,
        haloScale: CGFloat,
        coreIntensity: CGFloat,
        haloIntensity: CGFloat,
        haloExponent: CGFloat,
        haloPixels: Int
    ) -> SCNNode {
        let dist = CGFloat(cfg.skyDistance)

        let radians = coreAngularSizeDeg * .pi / 180.0
        let coreDiameter = max(1.0, 2.0 * dist * tan(0.5 * radians))
        let haloDiameter = max(coreDiameter * haloScale, coreDiameter + 1.0)

        let corePlane = SCNPlane(width: coreDiameter, height: coreDiameter)
        corePlane.cornerRadius = coreDiameter * 0.5

        let coreMat = SCNMaterial()
        coreMat.lightingModel = .constant
        coreMat.diffuse.contents = UIColor.black
        coreMat.blendMode = .add
        coreMat.readsFromDepthBuffer = false
        coreMat.writesToDepthBuffer = false
        coreMat.emission.contents = UIColor.white
        coreMat.emission.intensity = coreIntensity
        corePlane.firstMaterial = coreMat

        let coreNode = SCNNode(geometry: corePlane)
        coreNode.name = "SunDiscHDR"
        coreNode.castsShadow = false
        let bbCore = SCNBillboardConstraint()
        bbCore.freeAxes = .all
        coreNode.constraints = [bbCore]
        coreNode.renderingOrder = -20_000

        let haloPlane = SCNPlane(width: haloDiameter, height: haloDiameter)
        haloPlane.cornerRadius = haloDiameter * 0.5

        let haloMat = SCNMaterial()
        haloMat.lightingModel = .constant
        haloMat.diffuse.contents = UIColor.black
        haloMat.blendMode = .add
        haloMat.readsFromDepthBuffer = false
        haloMat.writesToDepthBuffer = false
        haloMat.emission.contents = sunHaloImage(diameter: max(256, haloPixels), exponent: haloExponent)
        haloMat.emission.intensity = haloIntensity
        haloMat.transparencyMode = .aOne
        haloPlane.firstMaterial = haloMat

        let haloNode = SCNNode(geometry: haloPlane)
        haloNode.name = "SunHaloHDR"
        haloNode.castsShadow = false
        let bbHalo = SCNBillboardConstraint()
        bbHalo.freeAxes = .all
        haloNode.constraints = [bbHalo]
        haloNode.renderingOrder = -19_990

        let group = SCNNode()
        group.addChildNode(haloNode)
        group.addChildNode(coreNode)
        return group
    }

    @MainActor
    func sunHaloImage(diameter: Int, exponent: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.clear.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let steps = 8

            var colors: [CGColor] = []
            var locations: [CGFloat] = []

            for i in 0...steps {
                let p = CGFloat(i) / CGFloat(steps)
                let a = pow(1.0 - p, max(0.1, exponent))
                colors.append(UIColor(white: 1.0, alpha: a).cgColor)
                locations.append(p)
            }

            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: locations
            ) else { return }

            let radius = min(size.width, size.height) * 0.5
            cg.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    @MainActor
    func prewarmSkyAndSun() {
        // Sun diffusion prewarm is idempotent.
        prewarmSunDiffusion()

        // Pre-compile sky + cloud shaders/materials on a background thread so the first
        // real-time camera pan doesn’t hitch when SceneKit lazily compiles pipelines.
        guard let view = scnView else { return }

        var objects: [Any] = []
        objects.reserveCapacity(16)

        objects.append(scene)
        objects.append(skyAnchor)

        if let sky = skyAnchor.childNode(withName: "SkyAtmosphere", recursively: true) {
            objects.append(sky)
        }
        if let dome = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: true) {
            objects.append(dome)
        }
        if let sun = sunDiscNode {
            objects.append(sun)
        }
        if let layer = cloudLayerNode ?? skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            objects.append(layer)
        }

        // Also include unique materials to force shader-modifier compilation.
        var mats: [SCNMaterial] = []
        mats.reserveCapacity(64)
        var seen = Set<ObjectIdentifier>()

        func harvest(from node: SCNNode) {
            if let g = node.geometry {
                for m in g.materials {
                    let id = ObjectIdentifier(m)
                    if seen.insert(id).inserted {
                        mats.append(m)
                    }
                }
            }
            for c in node.childNodes {
                harvest(from: c)
            }
        }

        for o in objects {
            if let n = o as? SCNNode {
                harvest(from: n)
            }
        }
        objects.append(contentsOf: mats)

        view.prepare(objects) { _ in
            // Intentionally ignored; preparation is best-effort.
        }
    }
}
