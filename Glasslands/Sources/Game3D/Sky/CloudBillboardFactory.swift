//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using a two-pass approach per puff:
//  1) Depth-mask pass: exact silhouette, writes DEPTH only (no colour).
//  2) Volumetric pass: your existing impostor shader, reads depth.
//  Keeps quality and .all billboarding, but removes full-screen cloud stalls.
//

import SceneKit
import UIKit

enum CloudBillboardFactory {

    @MainActor
    static func makeNode(
        from clusters: [CloudClusterSpec],
        atlas: CloudSpriteTexture.Atlas
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.castsShadow = false

        // Global size scale kept identical to previous builds.
        let GLOBAL_SIZE_SCALE: CGFloat = 0.58

        for cl in clusters {
            // Cluster anchor at centroid so children can stay in relative offsets.
            var ax: Float = 0, ay: Float = 0, az: Float = 0
            if !cl.puffs.isEmpty {
                for p in cl.puffs { ax += p.pos.x; ay += p.pos.y; az += p.pos.z }
                let inv = 1.0 / Float(cl.puffs.count)
                ax *= inv; ay *= inv; az *= inv
            }
            let anchor = SCNVector3(ax, ay, az)

            // One billboard per CLUSTER (keeps look identical to per-puff).
            let group = SCNNode()
            group.castsShadow = false
            group.position = anchor
            let bc = SCNBillboardConstraint()
            bc.freeAxes = .all
            group.constraints = [bc]

            for p in cl.puffs {
                let size = max(0.01, CGFloat(p.size) * GLOBAL_SIZE_SCALE)
                let half = max(0.001, size * 0.5)

                // --- Pass 1: depth mask (writes depth only, colour disabled) ---
                let maskPlane = SCNPlane(width: size, height: size)
                let maskMat = makeDepthMaskMaterial(halfWidth: half, halfHeight: half)
                maskPlane.firstMaterial = maskMat

                let maskNode = SCNNode(geometry: maskPlane)
                maskNode.castsShadow = false
                maskNode.position = SCNVector3(p.pos.x - ax, p.pos.y - ay, p.pos.z - az)
                var mEA = maskNode.eulerAngles
                mEA.z = Float(p.roll)
                maskNode.eulerAngles = mEA
                maskNode.renderingOrder = -100   // ensure depth writes happen first

                // --- Pass 2: volumetric shading (reads depth) ---
                let shadePlane = SCNPlane(width: size, height: size)
                let shadeMat = CloudImpostorProgram.makeMaterial(halfWidth: half, halfHeight: half)
                shadePlane.firstMaterial = shadeMat

                let sprite = SCNNode(geometry: shadePlane)
                sprite.castsShadow = false
                sprite.opacity = CGFloat(max(0, min(1, p.opacity)))
                sprite.position = SCNVector3(p.pos.x - ax, p.pos.y - ay, p.pos.z - az)
                var sEA = sprite.eulerAngles
                sEA.z = Float(p.roll)
                sprite.eulerAngles = sEA
                sprite.renderingOrder = 0

                if let t = p.tint {
                    sprite.geometry?.firstMaterial?.multiply.contents =
                        UIColor(red: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1.0)
                }

                group.addChildNode(maskNode)
                group.addChildNode(sprite)
            }

            root.addChildNode(group)
        }

        return root
    }

    // MARK: - Depth mask material (DEPTH ONLY, no colour writes)
    @MainActor
    private static func makeDepthMaskMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        // Silhouette only: same edge + macro shape as the volumetric shader.
        let frag = """
        #pragma transparent
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;
        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;
        float rimFeatherBoost;
        float rimFadePow;
        float shapeScale;
        float shapeLo;
        float shapeHi;
        float shapePow;
        float shapeSeed;

        #pragma declarations
        inline float hash1(float n){ return fract(sin(n) * 43758.5453123); }
        inline float noise3(float3 x){
            float3 p=floor(x), f=x-p; f=f*f*(3.0-2.0*f);
            const float3 off=float3(1.0,57.0,113.0);
            float n=dot(p,off);
            float n000=hash1(n+0.0), n100=hash1(n+1.0),
                  n010=hash1(n+57.0), n110=hash1(n+58.0),
                  n001=hash1(n+113.0),n101=hash1(n+114.0),
                  n011=hash1(n+170.0),n111=hash1(n+171.0);
            float nx00=mix(n000,n100,f.x), nx10=mix(n010,n110,f.x);
            float nx01=mix(n001,n101,f.x), nx11=mix(n011,n111,f.x);
            float nxy0=mix(nx00,nx10,f.y), nxy1=mix(nx01,nx11,f.y);
            return mix(nxy0,nxy1,f.z);
        }
        inline float macroMask2D(float2 uv, float ss, float slo, float shi, float spow, float sseed){
            float sA = noise3(float3(uv*ss + float2(sseed*0.13, sseed*0.29), 0.0));
            float sB = noise3(float3(uv*(ss*1.93) + float2(-sseed*0.51, sseed*0.07), 1.7));
            float m = 0.62*sA + 0.38*sB;
            m = smoothstep(slo, shi, m);
            m = pow(clamp(m,0.0,1.0), max(1.0, spow));
            return m;
        }

        #pragma body
        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;
        float2 halfs = float2(max(0.0001,impostorHalfW), max(0.0001,impostorHalfH));
        float s = max(halfs.x, halfs.y);
        float2 uvE = uv * halfs / s;

        float r = length(uvE);
        float nEdge = noise3(float3(uvE*3.15, 0.0));
        float rWobble = (nEdge*2.0-1.0) * edgeNoiseAmp;
        float rDist = r + rWobble;
        float cutR = 1.0 - clamp(edgeCut, 0.0, 0.49);
        if (rDist >= cutR) { discard_fragment(); }
        float featherW = clamp(edgeFeather * max(0.5, rimFeatherBoost), 0.0, 0.49);
        float rimSoft = smoothstep(cutR - featherW, cutR, rDist);
        float interior = pow(clamp(1.0 - rimSoft, 0.0, 1.0), max(1.0, rimFadePow));

        float sMask = macroMask2D(uvE*0.90, shapeScale, shapeLo, shapeHi, shapePow, shapeSeed);
        float edgeMask = interior * sMask;
        if (edgeMask < 0.01) { discard_fragment(); }

        // Depth pass only — colour is ignored (we disable colour writes in Swift).
        _output.color = float4(0.0, 0.0, 0.0, 0.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.blendMode = .replace
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = true
        if #available(iOS 15.0, *) {
            m.colorBufferWriteMask = []  // DEPTH-ONLY
        }
        m.shaderModifiers = [.fragment: frag]

        // Required sizes
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        // Defaults mirroring your volumetric material so silhouettes match exactly.
        m.setValue(0.12 as CGFloat,  forKey: "edgeFeather")
        m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
        m.setValue(0.16 as CGFloat,  forKey: "edgeNoiseAmp")
        m.setValue(1.90 as CGFloat,  forKey: "rimFeatherBoost")
        m.setValue(3.00 as CGFloat,  forKey: "rimFadePow")

        m.setValue(0.85 as CGFloat,  forKey: "shapeScale")
        m.setValue(0.30 as CGFloat,  forKey: "shapeLo")
        m.setValue(0.70 as CGFloat,  forKey: "shapeHi")
        m.setValue(2.00 as CGFloat,  forKey: "shapePow")
        m.setValue(0.77 as CGFloat,  forKey: "shapeSeed")

        return m
    }
}
