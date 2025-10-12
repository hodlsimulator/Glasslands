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
        if let pov = (scnView?.pointOfView ?? camNode) as SCNNode? {
            let look = -pov.presentation.simdWorldFront
            if simd_dot(dir, look) < 0 { dir = -dir }
        }
        sunDirWorld = dir

        if let sunLightNode {
            let origin = yawNode.presentation.position
            let incoming = SCNVector3(-dir.x, -dir.y, -dir.z)
            let target = SCNVector3(origin.x + incoming.x, origin.y + incoming.y, origin.z + incoming.z)
            sunLightNode.position = origin
            sunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }
        if let disc = sunDiscNode {
            let dist = CGFloat(cfg.skyDistance)
            disc.simdPosition = simd_float3(dir.x, dir.y, dir.z) * Float(dist)
        }
        applyCloudSunUniforms()
    }

    @MainActor
    func applyCloudSunUniforms() {
        let sunW = simd_normalize(sunDirWorld)
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunW, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials {
                    // sun-only white
                    m.setValue(sunViewV,        forKey: "sunDirView")
                    m.setValue(0.55 as CGFloat, forKey: "hgG")
                    m.setValue(1.00 as CGFloat, forKey: "baseWhite")
                    m.setValue(1.00 as CGFloat, forKey: "hiGain")

                    // ultra-dense + crisp, still fast (matches shader defaults)
                    m.setValue(9.00 as CGFloat,  forKey: "densityMul")
                    m.setValue(3.50 as CGFloat,  forKey: "thickness")
                    m.setValue(0.00 as CGFloat,  forKey: "densBias")
                    m.setValue(0.50 as CGFloat,  forKey: "stepMul")   // compat

                    m.setValue(0.94 as CGFloat,  forKey: "coverage")
                    m.setValue(0.0042 as CGFloat, forKey: "puffScale")
                    m.setValue(0.12 as CGFloat,  forKey: "edgeFeather")
                    m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
                    m.setValue(0.16 as CGFloat,  forKey: "edgeNoiseAmp")
                    m.setValue(0.62 as CGFloat,  forKey: "edgeErode")
                    m.setValue(0.78 as CGFloat,  forKey: "centreFill")

                    m.setValue(1.90 as CGFloat,  forKey: "rimFeatherBoost")
                    m.setValue(3.00 as CGFloat,  forKey: "rimFadePow")
                    m.setValue(1.80 as CGFloat,  forKey: "shapePow")

                    m.setValue(0.28 as CGFloat,  forKey: "microAmp")
                    m.setValue(0.55 as CGFloat,  forKey: "occK")
                }
            }
        }
    } 

    // HDR sun sprites (unchanged)
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
    
    @MainActor
    private func prewarmSkyAndSun() {
        // Kick the async compute pipeline compile now.
        prewarmSunDiffusion()

        // Offscreen-prepare the cloud layer’s shader-modifier materials once
        if let v = scnView,
           let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            v.prepare([layer]) { _ in /* no-op; just prewarm */ }
        }
    }
}
