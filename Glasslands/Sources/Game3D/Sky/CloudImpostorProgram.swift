//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric “puff” impostor shader modifier for SceneKit.
//  Magenta output indicates shader compile failure at runtime.
//  Keep helper functions in `#pragma declarations` (global scope).
//

import SceneKit
import simd

// Volumetric “puff” impostor for cloud billboards.
// Implemented as a SceneKit surface shader modifier that raymarches a soft ellipsoid volume.
// Output is premultiplied (rgb already includes alpha), so transparencyMode = .aOne is required.
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

    // Notes:
    // - Uses scn_node.inverseModelViewTransform to raymarch in local space.
    // - Uses scn_node.modelTransform[3].xyz to vary noise per puff even when materials are shared.
    // - Produces premultiplied output: col is accumulated using front-to-back compositing.
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

    inline float fbm(float3 p) {
        float v = 0.0;
        float a = 0.5;

        // Fixed octave count keeps Metal compilation predictable.
        for (int i = 0; i < 4; i++) {
            v += a * noise3(p);
            p = p * 2.02 + float3(17.1, 3.2, 5.9);
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
        float3 p = q * 2.35 + anchor * 0.00125 + seed;

        float n1 = fbm(p);
        float n2 = fbm(p * 2.75 + 11.3);

        float n = mix(n1, n2, 0.35);

        // Shape the noise into clumps. This keeps the cloud “vapour” look instead of streaks.
        float clumps = smoothstep(0.35, 0.80, n);

        return base * clumps;
    }

    #pragma body

    // Local ray origin and direction
    float3 ro = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

    // _surface.position is in view space; camera is at origin in view space.
    float3 rdView = normalize(_surface.position);
    float3 rd = normalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);

    // Convert world sun direction to local space.
    float3 sunW = normalize(u_sunDir);
    float3 sunL = normalize((scn_node.inverseModelTransform * float4(sunW, 0.0)).xyz);

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

    // If no intersection, output fully transparent.
    if (t1 <= max(t0, 0.0)) {
        _surface.diffuse = float4(0.0, 0.0, 0.0, 0.0);
    } else {

        // Raymarch step count.
        float q = clamp(u_quality, 0.0, 1.0);
        float stepsF = mix(14.0, 34.0, q);
        int steps = int(stepsF);

        float tStart = max(t0, 0.0);
        float dt = (t1 - tStart) / stepsF;

        // Jitter reduces banding, derived from local position + seed.
        float jitter = fract(sin(dot(_surface.position.xy + u_seed, float2(12.9898, 78.233))) * 43758.5453);
        float t = tStart + dt * jitter;

        float trans = 1.0;
        float3 col = float3(0.0);

        // Per-puff anchor (world translation) for variation.
        float3 anchor = scn_node.modelTransform[3].xyz;

        // Precompute phase term scaling
        float g = clamp(u_phaseG, -0.95, 0.95);

        // HG phase can spike a lot near the sun; scale down to stay SDR.
        float phaseScale = 0.08;

        for (int i = 0; i < 34; i++) {
            if (i >= steps) { break; }
            if (trans < 0.02) { break; }

            float3 p = ro + rd * t;

            // Normalised coords in the ellipsoid volume.
            float3 qv = float3(p.x / hw, p.y / hh, p.z / hz);

            float d = densityAt(qv, anchor, u_edgeFeather, u_heightFade, u_seed);
            if (d > 0.0005) {

                // Normalise step length to unit size so densityMul behaves consistently.
                float stepU = dt / unit;

                // Opacity step via Beer-Lambert.
                float sigma = d * u_densityMul;
                float a = 1.0 - exp(-sigma * stepU);

                if (a > 0.0001) {

                    // Cheap self-shadow: 2 taps along sun direction.
                    float shadow = 1.0;
                    float shadowStep = unit * 0.55;

                    float3 sp = p + sunL * shadowStep;
                    float3 sq1 = float3(sp.x / hw, sp.y / hh, sp.z / hz);
                    float ds1 = densityAt(sq1, anchor, u_edgeFeather, u_heightFade, u_seed * 1.37);
                    shadow *= exp(-ds1 * u_densityMul * 0.35);

                    sp = p + sunL * shadowStep * 2.0;
                    float3 sq2 = float3(sp.x / hw, sp.y / hh, sp.z / hz);
                    float ds2 = densityAt(sq2, anchor, u_edgeFeather, u_heightFade, u_seed * 2.11);
                    shadow *= exp(-ds2 * u_densityMul * 0.25);

                    // Henyey-Greenstein phase (scaled).
                    float mu = dot(rd, sunL);
                    float denom = pow(max(1.0 + g * g - 2.0 * g * mu, 1e-3), 1.5);
                    float phase = ((1.0 - g * g) / denom) * phaseScale;

                    float light = clamp(u_ambient + u_lightGain * shadow * phase, 0.0, 1.0);
                    float3 sampleCol = float3(u_baseWhite) * light;

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

        // Premultiplied output.
        _surface.diffuse = float4(col, alpha);
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

        // Clouds should not write depth (transparent), but can read depth for correct occlusion.
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false

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
