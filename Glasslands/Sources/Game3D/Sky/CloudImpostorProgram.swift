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
// Implemented as a SceneKit fragment shader modifier that raymarches a soft ellipsoid volume.
// Output is premultiplied (rgb already includes alpha).
enum CloudImpostorProgram {

    // MARK: - Uniform keys (SceneKit material values)

    static let kHalfWidth = "u_halfWidth"
    static let kHalfHeight = "u_halfHeight"
    static let kThickness = "u_thickness"
    static let kDensityMul = "u_densityMul"
    static let kPhaseG = "u_phaseG"
    static let kSeed = "u_seed"
    static let kHeightFade = "u_heightFade"
    static let kEdgeFeather = "u_edgeFeather"
    static let kBaseWhite = "u_baseWhite"
    static let kLightGain = "u_lightGain"
    static let kAmbient = "u_ambient"
    static let kQuality = "u_quality"
    static let kSunDir = "u_sunDir"

    // MARK: - Shader modifier

    // Goals:
    // - Restore the “real cloud” interior from 5f739a9 (phase + soft self-shadow + multi-scale clumps).
    // - Remove visible quad edges (hard square / rectangle silhouettes).
    // - Ensure alpha written by the shader actually drives per-fragment transparency.
    // - Keep render cost down versus 5f739a9 (fewer steps, fewer noise octaves, one shadow tap, early UV reject).
    //
    // Notes:
    // - Implemented as a fragment shader modifier with `#pragma transparent` so SceneKit honours alpha output.
    // - Output is premultiplied (rgb already includes alpha).

    private static let shader: String = """
    #pragma transparent

    #pragma arguments
    float u_halfWidth;
    float u_halfHeight;
    float u_thickness;
    float u_densityMul;
    float u_phaseG;
    float u_seed;
    float u_heightFade;
    float u_edgeFeather;
    float u_baseWhite;
    float u_lightGain;
    float u_ambient;
    float u_quality;
    float3 u_sunDir;

    #pragma declaration

    inline float hash11(float n) { return fract(sin(n) * 43758.5453123); }
    inline float hash31(float3 p) { return hash11(dot(p, float3(127.1, 311.7, 74.7))); }

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
        // 3 octaves (kept cheap; edge detail comes from additional single-noise taps).
        for (int i = 0; i < 3; i++) {
            v += a * noise3(p);
            p = p * 2.02 + float3(17.1, 3.2, 5.9);
            a *= 0.5;
        }
        return v;
    }

    inline float densityAt(
        float3 q,         // normalised volume coords (roughly -1..1)
        float3 anchor,    // per-puff anchor (world translation)
        float edgeFeather,
        float heightFade,
        float seed
    ) {
        float r = length(q);

        // Build a local noise domain first (used for edge warping + interior clumps).
        float3 p = q * 2.15 + anchor * 0.00125 + seed;

        // Domain warp breaks up axis-aligned noise and stops "blocky" silhouettes.
        float3 warp = float3(
            noise3(p * 0.65 + float3(10.0, 0.0, 0.0)),
            noise3(p * 0.65 + float3(0.0, 37.0, 0.0)),
            noise3(p * 0.65 + float3(0.0, 0.0, 91.0))
        );
        p += (warp - 0.5) * 0.85;

        // Noisy edge warp (less perfect discs).
        float rimN = noise3(p * 1.35 + 7.1);
        float rw = r + (rimN - 0.5) * 0.14;
        float edge = 1.0 - smoothstep(1.0 - edgeFeather, 1.0, rw);

        // Soft fade at top/bottom with a tiny noisy bias (avoids a perfectly flat cap).
        float y01 = q.y * 0.5 + 0.5;
        y01 = clamp(y01 + (noise3(p * 0.90 + 5.7) - 0.5) * 0.08, 0.0, 1.0);

        float yFade = smoothstep(0.0, heightFade, y01) * (1.0 - smoothstep(1.0 - heightFade, 1.0, y01));
        float base = edge * yFade;
        if (base <= 0.0) { return 0.0; }

        // Multi-scale clumps.
        float n1 = fbmFast(p);
        float n2 = fbmFast(p * 2.35 + 11.3);
        float n = mix(n1, n2, 0.45);

        // Add a small amount of higher-frequency billow to keep edges lively.
        float billow = 1.0 - abs(2.0 * noise3(p * 4.5 + 19.2) - 1.0);
        n = n + 0.18 * billow - 0.08 * (rimN - 0.5);

        // Shape into soft clumps.
        float clumps = smoothstep(0.32, 0.82, n);
        return base * clumps;
    }

    #pragma body

    // Default: fully transparent.
    _output.color = float4(0.0);

    // UV-based circular mask to kill visible quad corners.
    float2 uv = _surface.diffuseTexcoord;
    float2 q2 = (uv - float2(0.5, 0.5)) * 2.0;
    float r2 = length(q2);

    // Hard reject a little outside the unit circle to skip work entirely.
    if (r2 > 1.02) {
        discard_fragment();
    } else {
        // Soft feather towards the rim (prevents “card” silhouettes).
        float uvMask = 1.0 - smoothstep(0.96, 1.02, r2);

        // Local ray origin and direction.
        float3 ro = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

        // _surface.position is in view space; camera is at origin in view space.
        float3 rdView = normalize(_surface.position);
        float3 rd = normalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);

        // Convert world sun direction to local space.
        float3 sunW = normalize(u_sunDir);
        float3 sunL = normalize((scn_node.inverseModelTransform * float4(sunW, 0.0)).xyz);

        // Slight shrink so density reaches zero before the plane boundary.
        float hw = max(0.001, u_halfWidth * 0.97);
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

        // If no intersection, output fully transparent.
        if (t1 <= max(t0, 0.0)) {
            discard_fragment();
        } else {
            // Per-puff anchor (world translation) for variation.
            float3 anchor = scn_node.modelTransform[3].xyz;

            // Raymarch step count (balanced for interior smoothness).
            float q = clamp(u_quality, 0.0, 1.0);
            float stepsF = mix(12.0, 26.0, q);
            int steps = int(stepsF);

            float tStart = max(t0, 0.0);
            float dt = (t1 - tStart) / stepsF;

            // Jitter reduces banding; include the anchor so neighbouring puffs don't share patterns.
            float jitter = fract(sin(dot(uv + float2(anchor.x, anchor.z) * 0.00007 + u_seed, float2(12.9898, 78.233))) * 43758.5453);
            float t = tStart + dt * jitter;

            float trans = 1.0;
            float3 col = float3(0.0);

            // Precompute per-fragment constants that were previously inside the loop.
            float stepU = dt / unit;
            float shadowStep = unit * 0.55;

            float g = clamp(u_phaseG, -0.95, 0.95);
            float mu = dot(rd, sunL);
            float vP = max(1.0 + g * g - 2.0 * g * mu, 1e-3);
            float denom = vP * sqrt(vP);                 // == pow(vP, 1.5)
            float phase = ((1.0 - g * g) / denom) * 0.08; // phaseScale baked in

            float3 baseWhite3 = float3(u_baseWhite);

            // Fixed max loop keeps compilation predictable.
            for (int i = 0; i < 28; i++) {
                if (i >= steps) { break; }
                if (trans < 0.03) { break; }

                float3 p = ro + rd * t;

                // Normalised coords in the ellipsoid volume.
                float3 qv = float3(p.x / hw, p.y / hh, p.z / hz);

                float d = densityAt(qv, anchor, u_edgeFeather, u_heightFade, u_seed);

                if (d > 0.0005) {
                    // Opacity step via Beer-Lambert.
                    float sigma = d * u_densityMul;
                    float a = 1.0 - exp(-sigma * stepU);

                    if (a > 0.0001) {
                        // One-tap self-shadow.
                        float shadow = 1.0;
                        float3 sp = p + sunL * shadowStep;
                        float3 sq = float3(sp.x / hw, sp.y / hh, sp.z / hz);
                        float ds = densityAt(sq, anchor, u_edgeFeather, u_heightFade, u_seed * 1.37);
                        shadow *= exp(-ds * u_densityMul * 0.45);

                        float light = clamp(u_ambient + u_lightGain * shadow * phase, 0.0, 1.0);
                        float3 sampleCol = baseWhite3 * light;

                        // Front-to-back premultiplied compositing.
                        col += trans * a * sampleCol;
                        trans *= (1.0 - a);
                    }
                }

                t += dt;
            }

            float alpha = 1.0 - trans;

            // Clamp to SDR.
            col = clamp(col, float3(0.0), float3(1.0));
            alpha = clamp(alpha, 0.0, 1.0);

            // UV rim mask kills any remaining card edge.
            col *= uvMask;
            alpha *= uvMask;

            // Premultiplied output.
            _output.color = float4(col, alpha);
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

        // Premultiplied alpha output from shader.
        m.transparencyMode = .aOne
        m.blendMode = .alpha

        // Transparent objects: read depth for occlusion but do not write.
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false

        // Neutral defaults (shader writes the final colour/alpha).
        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white

        // Shader modifier does the rendering.
        m.shaderModifiers = [.fragment: shader]

        // Default uniform values.
        m.setValue(NSNumber(value: Float(halfWidth)), forKey: kHalfWidth)
        m.setValue(NSNumber(value: Float(halfHeight)), forKey: kHalfHeight)
        m.setValue(NSNumber(value: thickness), forKey: kThickness)
        m.setValue(NSNumber(value: densityMul), forKey: kDensityMul)
        m.setValue(NSNumber(value: phaseG), forKey: kPhaseG)
        m.setValue(NSNumber(value: seed), forKey: kSeed)
        m.setValue(NSNumber(value: heightFade), forKey: kHeightFade)
        m.setValue(NSNumber(value: edgeFeather), forKey: kEdgeFeather)
        m.setValue(NSNumber(value: baseWhite), forKey: kBaseWhite)
        m.setValue(NSNumber(value: lightGain), forKey: kLightGain)
        m.setValue(NSNumber(value: ambient), forKey: kAmbient)
        m.setValue(NSNumber(value: quality), forKey: kQuality)
        m.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: kSunDir)

        return m
    }
}
