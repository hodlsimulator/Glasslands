//
//  FirstPersonEngine+Sky.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Sun + sky helpers, plus cloud-material uniform updates.
//  This revision makes billboards sun-lit white (no self-light) and
//  dials down per-pixel work to reduce lag.
//

import SceneKit
import simd
import UIKit
import CoreGraphics

extension FirstPersonEngine {

    // MARK: - Sun direction

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

        if let pov = (scnView?.pointOfView ?? camNode) as SCNNode? {
            // Keep the sun in the camera’s front hemisphere for stable billboard shading
            let look = -pov.presentation.simdWorldFront
            if simd_dot(dir, look) < 0 { dir = -dir }
        }

        sunDirWorld = dir

        // Aim the SCNLight (directional lights emit along -Z)
        if let sunLightNode {
            let origin = yawNode.presentation.position
            let incoming = SCNVector3(-dir.x, -dir.y, -dir.z)
            let target = SCNVector3(origin.x + incoming.x, origin.y + incoming.y, origin.z + incoming.z)
            sunLightNode.position = origin
            sunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }

        // HDR sprite sun follows the direction
        if let disc = sunDiscNode {
            let dist = CGFloat(cfg.skyDistance)
            disc.simdPosition = simd_float3(dir.x, dir.y, dir.z) * Float(dist)
        }

        applyCloudSunUniforms()
    }

    // MARK: - Apply sun → cloud uniforms (billboards + volumetrics)

    @MainActor
    func applyCloudSunUniforms() {
        let sunW = simd_normalize(sunDirWorld)
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunW, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        // --- Billboard impostors (pure white, sun-only; faster marching) ---
        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials {
                    // Direction + phase
                    m.setValue(sunViewV,           forKey: "sunDirView")
                    m.setValue(0.56 as CGFloat,    forKey: "hgG")

                    // Sun-only white (no rim/ambient)
                    m.setValue(1.00 as CGFloat,    forKey: "baseWhite")
                    m.setValue(3.80 as CGFloat,    forKey: "hiGain")     // brighter response to sun
                    m.setValue(0.00 as CGFloat,    forKey: "edgeSoft")   // kill rim lift

                    // Absorption / density
                    m.setValue(0.00 as CGFloat,    forKey: "densBias")   // <- was 1.0 (made everything dark)
                    m.setValue(1.80 as CGFloat,    forKey: "densityMul")
                    m.setValue(2.60 as CGFloat,    forKey: "thickness")

                    // Detail & shadow
                    m.setValue(0.22 as CGFloat,    forKey: "microAmp")
                    m.setValue(0.95 as CGFloat,    forKey: "occK")

                    // Quality/perf
                    m.setValue(0.70 as CGFloat,    forKey: "stepMul")    // ~14 steps instead of ~20
                }
            }
        }

        // --- Volumetric layer (true ray-march) ---
        // Keep it sun-only and fast: configure the live uniforms once.
        VolCloudUniformsStore.shared.configure(
            baseY: 400,
            topY: 1400,
            coverage: 0.48,
            densityMul: 0.95,   // slightly lighter absorption
            stepMul: 0.65,      // fewer steps
            horizonLift: 0.10,
            detailMul: 0.90,
            puffScale: 0.0048,
            puffStrength: 0.62,
            macroScale: 0.00035,
            macroThreshold: 0.58
        )

        // Atmosphere sky gets the sun too (not used for cloud light)
        if let sky = skyAnchor.childNode(withName: "SkyAtmosphere", recursively: false),
           let mat = sky.geometry?.firstMaterial {
            mat.setValue(SCNVector3(sunW.x, sunW.y, sunW.z), forKey: "sunDirWorld")
            mat.setValue(SCNVector3(1.0, 0.97, 0.92),        forKey: "sunTint")
            mat.setValue(1.9 as CGFloat,                     forKey: "turbidity")
            mat.setValue(0.46 as CGFloat,                    forKey: "mieG")
            mat.setValue(3.00 as CGFloat,                    forKey: "exposure")
            mat.setValue(0.10 as CGFloat,                    forKey: "horizonLift")
        }
    }

    // MARK: - HDR sun sprites (unchanged)

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
        let bbCore = SCNBillboardConstraint(); bbCore.freeAxes = .all
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
        let bbHalo = SCNBillboardConstraint(); bbHalo.freeAxes = .all
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
}
