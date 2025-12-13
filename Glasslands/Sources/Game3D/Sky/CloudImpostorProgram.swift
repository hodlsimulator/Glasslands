//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric “puff” impostor shader modifier for SceneKit.
//  Magenta output indicates shader compile failure at runtime.
//  Keep helper functions in `#pragma declaration` (global scope).
//

import SceneKit
import simd
import UIKit

// Volumetric “puff” impostor for cloud billboards.
// Implemented as a SceneKit surface shader modifier that integrates density through a soft ellipsoid.
// Opacity is driven via `_surface.transparent.a` (SceneKit’s transparent channel), so the material must
// have `transparent.contents` set to enable the transparent slot.
enum CloudImpostorProgram {

    // MARK: - Uniform keys (SceneKit material values)

    static let kHalfWidth     = "u_halfWidth"
    static let kHalfHeight    = "u_halfHeight"
    static let kThickness     = "u_thickness"
    static let kDensityMul    = "u_densityMul"
    static let kPhaseG        = "u_phaseG"
    static let kSeed          = "u_seed"
    static let kHeightFade    = "u_heightFade"
    static let kEdgeFeather   = "u_edgeFeather"
    static let kBaseWhite     = "u_baseWhite"
    static let kLightGain     = "u_lightGain"
    static let kAmbient       = "u_ambient"
    static let kQuality       = "u_quality"
    static let kSunDir        = "u_sunDir"

    // MARK: - Shader modifier

    private static let shader: String = """
    #pragma arguments
    float  u_halfWidth;
    float  u_halfHeight;
    float  u_thickness;
    float  u_densityMul;
    float  u_phaseG;
    float  u_seed;
    float  u_heightFade;
    float  u_edgeFeather;
    float  u_baseWhite;
    float  u_lightGain;
    float  u_ambient;
    float  u_quality;
    float3 u_sunDir;

    #pragma declaration

    inline float hash11(float n) {
        return fract(sin(n) * 43758.5453123);
    }

    inline float hash31(float3 p) {
        return hash11(dot(p, float3(127.1, 311.7, 74.7)));
    }

    inline float noise3(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);

        float n000 = hash31(i + float3(0.0, 0.0, 0.0));
        float n100 = hash31(i + float3(1.0, 0.0, 0.0));
        float n010 = hash31(i + float3(0.0, 1.0, 0.0));
        float n110 = hash31(i + float3(1.0, 1.0, 0.0));
        float n001 = hash31(i + float3(0.0, 0.0, 1.0));
        float n101 = hash31(i + float3(1.0, 0.0, 1.0));
        float n011 = hash31(i + float3(0.0, 1.0, 1.0));
        float n111 = hash31(i + float3(1.0, 1.0, 1.0));

        float n00 = mix(n000, n100, u.x);
        float n10 = mix(n010, n110, u.x);
        float n01 = mix(n001, n101, u.x);
        float n11 = mix(n011, n111, u.x);

        float n0 = mix(n00, n10, u.y);
        float n1 = mix(n01, n11, u.y);

        return mix(n0, n1, u.z);
    }

    inline float fbmFast(float3 p) {
        float v = 0.0;
        float a = 0.5;

        // Fewer octaves: big perf win for lots of sprites.
        for (int i = 0; i < 3; i++) {
            v += a * noise3(p);
            p = p * 2.01 + float3(17.1, 3.2, 5.9);
            a *= 0.5;
        }
        return v;
    }

    inline float densityAt(
        float3 q,              // normalised volume coords (roughly -1..1)
        float3 anchor,         // per-puff anchor (world translation)
        float  edgeFeather,
        float  heightFade,
        float  seed
    ) {
        float r = length(q);

        // Radial edge fade so the plane never shows as a hard square.
        float edge = 1.0 - smoothstep(1.0 - edgeFeather, 1.0, r);

        // Soft fade at top/bottom to avoid a hard clipping plane.
        float y01 = q.y * 0.5 + 0.5; // -1..1 -> 0..1
        float yFade = smoothstep(0.0, heightFade, y01) * (1.0 - smoothstep(1.0 - heightFade, 1.0, y01));

        float base = edge * yFade;
        if (base <= 0.0) { return 0.0; }

        // Multi-scale noise. Anchor introduces per-instance variation even with shared materials.
        float3 p = q * 2.20 + anchor * 0.00110 + seed;

        float n = fbmFast(p);
        float clumps = smoothstep(0.42, 0.82, n);

        return base * clumps;
    }

    #pragma body

    // Fast corner reject using the plane UVs.
    // For any pixel outside the unit circle in XY, density is guaranteed 0 for the whole ray,
    // so the expensive integration can be skipped.
    float2 uv = _surface.diffuseTexcoord;
    float2 q2 = (uv - float2(0.5, 0.5)) * 2.0;
    float r2 = length(q2);
    if (r2 > 1.0) {
        _surface.diffuse = float4(1.0, 1.0, 1.0, 1.0);
        _surface.transparent = float4(1.0, 1.0, 1.0, 0.0);
    } else {

        // Local ray origin and direction.
        float3 ro = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

        // _surface.position is in view space; camera is at origin in view space.
        float3 rdView = normalize(_surface.position);
        float3 rd = normalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);

        // Slight shrink so density reaches zero before the plane boundary.
        float hw = max(0.001, u_halfWidth  * 0.97);
        float hh = max(0.001, u_halfHeight * 0.97);

        // Thickness is a ratio multiplied by the puff size.
        float unit = max(hw, hh);
        float hz = max(0.001, u_thickness) * unit;

        float3 bmin = float3(-hw, -hh, -hz);
        float3 bmax = float3( hw,  hh,  hz);

        // Ray-box intersection (slab method).
        float3 t0s = (bmin - ro) / rd;
        float3 t1s = (bmax - ro) / rd;
        float3 tsm = min(t0s, t1s);
        float3 tsM = max(t0s, t1s);

        float t0 = max(max(tsm.x, tsm.y), tsm.z);
        float t1 = min(min(tsM.x, tsM.y), tsM.z);

        if (t1 <= max(t0, 0.0)) {
            _surface.diffuse = float4(1.0, 1.0, 1.0, 1.0);
            _surface.transparent = float4(1.0, 1.0, 1.0, 0.0);
        } else {

            // Raymarch steps (reduced for performance).
            float q = clamp(u_quality, 0.0, 1.0);
            float stepsF = mix(5.0, 11.0, q);
            int steps = int(stepsF);

            float tStart = max(t0, 0.0);
            float dt = (t1 - tStart) / stepsF;

            // Jitter reduces banding.
            float jitter = fract(sin(dot(uv + u_seed, float2(12.9898, 78.233))) * 43758.5453);
            float t = tStart + dt * jitter;

            float trans = 1.0;
            float shadeAcc = 0.0;

            // Per-puff anchor (world translation) for variation.
            float3 anchor = scn_node.modelTransform[3].xyz;

            // Integrate opacity and a very light “shade” term.
            // Clouds stay white: shade is clamped very high.
            for (int i = 0; i < 12; i++) {
                if (i >= steps) { break; }
                if (trans < 0.06) { break; }

                float3 p = ro + rd * t;

                float3 qv = float3(p.x / hw, p.y / hh, p.z / hz);
                float d = densityAt(qv, anchor, u_edgeFeather, u_heightFade, u_seed);

                if (d > 0.0006) {
                    float stepU = dt / unit;
                    float sigma = d * u_densityMul;
                    float aStep = 1.0 - exp(-sigma * stepU);

                    if (aStep > 0.0002) {
                        float w = trans * aStep;

                        // Very subtle shading from density only (no sun phase, no shadow taps).
                        float bright = 1.0 - 0.10 * d;
                        bright = clamp(bright, 0.90, 1.0);

                        shadeAcc += w * bright;
                        trans *= (1.0 - aStep);
                    }
                }

                t += dt;
            }

            float alpha = clamp(1.0 - trans, 0.0, 1.0);

            if (alpha <= 0.0001) {
                _surface.diffuse = float4(1.0, 1.0, 1.0, 1.0);
                _surface.transparent = float4(1.0, 1.0, 1.0, 0.0);
            } else {
                float shade = shadeAcc / max(alpha, 1e-4);
                shade = clamp(shade, 0.92, 1.0);

                float3 rgb = float3(clamp(shade * u_baseWhite, 0.0, 1.0));

                // Diffuse stays opaque; opacity is provided by transparent.a.
                _surface.diffuse = float4(rgb, 1.0);
                _surface.transparent = float4(1.0, 1.0, 1.0, alpha);
            }
        }
    }
    """

    // MARK: - Material factory

    @MainActor
    static func makeMaterial(
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        thickness: Float = 4.2,
        densityMul: Float = 0.95,
        phaseG: Float = 0.62,
        seed: Float = 0.0,
        heightFade: Float = 0.34,
        edgeFeather: Float = 0.38,
        baseWhite: Float = 1.0,
        lightGain: Float = 2.0,
        ambient: Float = 0.22,
        quality: Float = 0.60,
        sunDir: simd_float3 = simd_float3(0.3, 0.9, 0.1)
    ) -> SCNMaterial {

        let m = SCNMaterial()
        m.lightingModel = .constant

        // Enable the transparent slot so `_surface.transparent` is honoured.
        // aOne uses the alpha channel (alpha=1 opaque, alpha=0 fully transparent).
        m.transparent.contents = UIColor.white
        m.transparencyMode = .aOne

        // Blending for soft vapour edges.
        m.blendMode = .alpha

        // Transparent objects: read depth for occlusion but do not write.
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false

        // Material colours stay neutral.
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white

        // Shader modifier does the rendering.
        m.shaderModifiers = [.surface: shader]

        // Default uniform values.
        m.setValue(NSNumber(value: Float(halfWidth)),  forKey: kHalfWidth)
        m.setValue(NSNumber(value: Float(halfHeight)), forKey: kHalfHeight)

        m.setValue(NSNumber(value: thickness),    forKey: kThickness)
        m.setValue(NSNumber(value: densityMul),   forKey: kDensityMul)
        m.setValue(NSNumber(value: phaseG),       forKey: kPhaseG)
        m.setValue(NSNumber(value: seed),         forKey: kSeed)
        m.setValue(NSNumber(value: heightFade),   forKey: kHeightFade)
        m.setValue(NSNumber(value: edgeFeather),  forKey: kEdgeFeather)

        m.setValue(NSNumber(value: baseWhite),    forKey: kBaseWhite)
        m.setValue(NSNumber(value: lightGain),    forKey: kLightGain)
        m.setValue(NSNumber(value: ambient),      forKey: kAmbient)
        m.setValue(NSNumber(value: quality),      forKey: kQuality)

        m.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: kSunDir)

        return m
    }
}
