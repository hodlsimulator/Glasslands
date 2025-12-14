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

        // Whiter (still SDR), a touch sharper, and cheaper (fewer raymarch steps).
        let densityMul: Float = 1.02
        let thickness: Float = 4.5
        let phaseG: Float = 0.60
        let ambient: Float = 0.36
        let baseWhite: Float = 1.0
        let lightGain: Float = 3.35
        let quality: Float = 0.35

        // Extra lighting controls (cheap, but makes the clouds read more like real vapour).
        let powderK: Float = 0.85
        let edgeLight: Float = 3.0
        let backlight: Float = Float(cloudSunBacklight)

        // Lower feather = crisper cloud edge; still soft enough to hide the quad.
        let edgeFeather: Float = 0.26
        let heightFade: Float = 0.28

        layer.enumerateChildNodes { node, _ in
            guard let plane = node.geometry as? SCNPlane, let mat = plane.firstMaterial else { return }

            // Clouds are a sky element and always sit behind terrain. Rendering them before the world (and
            // with depth reads disabled) avoids the tile-resolve stalls that show up as "lag" on iOS GPUs.
            // Terrain (opaque) will overwrite them later in the frame.
            node.renderingOrder = -15_000
            mat.readsFromDepthBuffer = false
            mat.writesToDepthBuffer = false

            mat.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: CloudImpostorProgram.kSunDir)
            mat.setValue(NSNumber(value: densityMul), forKey: CloudImpostorProgram.kDensityMul)
            mat.setValue(NSNumber(value: thickness), forKey: CloudImpostorProgram.kThickness)
            mat.setValue(NSNumber(value: phaseG), forKey: CloudImpostorProgram.kPhaseG)
            mat.setValue(NSNumber(value: ambient), forKey: CloudImpostorProgram.kAmbient)
            mat.setValue(NSNumber(value: baseWhite), forKey: CloudImpostorProgram.kBaseWhite)
            mat.setValue(NSNumber(value: lightGain), forKey: CloudImpostorProgram.kLightGain)
            mat.setValue(NSNumber(value: quality), forKey: CloudImpostorProgram.kQuality)
            mat.setValue(NSNumber(value: powderK), forKey: CloudImpostorProgram.kPowderK)
            mat.setValue(NSNumber(value: edgeLight), forKey: CloudImpostorProgram.kEdgeLight)
            mat.setValue(NSNumber(value: backlight), forKey: CloudImpostorProgram.kBacklight)
            mat.setValue(NSNumber(value: edgeFeather), forKey: CloudImpostorProgram.kEdgeFeather)
            mat.setValue(NSNumber(value: heightFade), forKey: CloudImpostorProgram.kHeightFade)
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
