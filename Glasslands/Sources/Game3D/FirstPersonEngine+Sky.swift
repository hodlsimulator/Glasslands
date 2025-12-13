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
        let sunW = simd_normalize(sunDirWorld)
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunW, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                // Sun direction is in view space so camera-facing impostors behave consistently.
                m.setValue(sunViewV, forKey: "sunDirView")

                // Phase / highlight response.
                m.setValue(0.62 as CGFloat, forKey: "hgG")
                m.setValue(1.00 as CGFloat, forKey: "baseWhite")
                m.setValue(1.65 as CGFloat, forKey: "lightGain")
                m.setValue(1.00 as CGFloat, forKey: "hiGain")

                // Thick, fluffy scattered cumulus (matches the current CloudImpostorProgram defaults).
                m.setValue(14.00 as CGFloat, forKey: "densityMul")
                m.setValue(5.60 as CGFloat, forKey: "thickness")
                m.setValue(-0.02 as CGFloat, forKey: "densBias")
                m.setValue(0.86 as CGFloat, forKey: "coverage")
                m.setValue(0.0036 as CGFloat, forKey: "puffScale")

                // Silhouette shaping.
                m.setValue(0.16 as CGFloat, forKey: "edgeFeather")
                m.setValue(0.07 as CGFloat, forKey: "edgeCut")
                m.setValue(0.18 as CGFloat, forKey: "edgeNoiseAmp")
                m.setValue(2.10 as CGFloat, forKey: "rimFeatherBoost")
                m.setValue(2.80 as CGFloat, forKey: "rimFadePow")

                // Macro breakup inside each puff.
                m.setValue(1.05 as CGFloat, forKey: "shapeScale")
                m.setValue(0.42 as CGFloat, forKey: "shapeLo")
                m.setValue(0.70 as CGFloat, forKey: "shapeHi")
                m.setValue(2.15 as CGFloat, forKey: "shapePow")

                // Higher = sun is more “covered” through thick cores.
                m.setValue(0.70 as CGFloat, forKey: "occK")

                // Compatibility knobs (safe if ignored by a given shader variant).
                m.setValue(0.50 as CGFloat, forKey: "stepMul")
                m.setValue(0.62 as CGFloat, forKey: "edgeErode")
                m.setValue(0.78 as CGFloat, forKey: "centreFill")
                m.setValue(0.28 as CGFloat, forKey: "microAmp")
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
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    @MainActor
    func prewarmSkyAndSun() {
        // Keep this lightweight. Sun diffusion prewarm is handled separately and is idempotent.
        prewarmSunDiffusion()
    }
}
