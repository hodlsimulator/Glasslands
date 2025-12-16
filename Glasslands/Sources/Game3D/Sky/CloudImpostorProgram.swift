//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Performance goals:
//  - Reduce fragment cost when many puffs overlap (overdraw) by adapting ray steps to screen size.
//  - Avoid doing expensive shadow probes every step.
//  - Keep the look the same (or slightly better) by only reducing work where it’s not visible.
//

import Foundation
import SceneKit
import CoreGraphics
import simd

enum CloudImpostorProgram {

    enum Kind: Int {
        case volumetricBillboard = 0
        case shadowProxy = 1
    }

    // Shader modifier argument keys
    static let kCloudZ = "cloud_z"
    static let kSlabHalf = "slab_half"
    static let kDensityMul = "densityMul"
    static let kThickness = "slab_half"
    static let kPhaseG = "phaseG"
    static let kAmbient = "ambient"
    static let kBaseWhite = "baseWhite"
    static let kSunDir = "sun_dir"
    static let kShadowOnly = "shadow_only"
    static let kDitherDepth = "dither_depth"

    static let kLightGain = "lightGain"
    static let kQuality = "quality"
    static let kPowderK = "powderK"
    static let kEdgeLight = "edgeLight"
    static let kBacklight = "backlight"
    static let kEdgeFeather = "edgeFeather"
    static let kHeightFade = "heightFade"
    // Behaviour toggles (UserDefaults)
    // Default is ON because it’s the fastest path on device.
    private static let kDefaultsDitherDepthWrite = "clouds.ditherDepthWrite"

    // Cached shader source (same for all materials; behaviour toggled via uniforms)
    private static let fragmentSource: String = {
        return """
        #pragma arguments
        float cloud_z;
        float slab_half;
        float3 sun_dir;
        float shadow_only;
        float dither_depth;
        float densityMul;

        // --- Hash / noise ------------------------------------------------------

        float hash11(float x) {
            return fract(sin(x) * 43758.5453123);
        }

        float hash21(float2 p) {
            return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453123);
        }

        float noise3(float3 p) {
            float3 i = floor(p);
            float3 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);

            float n = dot(i, float3(1.0, 57.0, 113.0));

            float a = hash11(n + 0.0);
            float b = hash11(n + 1.0);
            float c = hash11(n + 57.0);
            float d = hash11(n + 58.0);

            float e = hash11(n + 113.0);
            float g = hash11(n + 114.0);
            float h = hash11(n + 170.0);
            float j = hash11(n + 171.0);

            float x1 = mix(a, b, f.x);
            float x2 = mix(c, d, f.x);
            float y1 = mix(x1, x2, f.y);

            float x3 = mix(e, g, f.x);
            float x4 = mix(h, j, f.x);
            float y2 = mix(x3, x4, f.y);

            return mix(y1, y2, f.z);
        }

        float fbmFast(float3 p) {
            float v = 0.0;
            float a = 0.5;
            float3 q = p;

            // 3 octaves (kept for quality; overall cost is dominated by step count + overdraw)
            v += a * noise3(q); q = q * 2.02 + 17.13; a *= 0.5;
            v += a * noise3(q); q = q * 2.02 + 17.13; a *= 0.5;
            v += a * noise3(q);

            return v;
        }

        float densityAt(float3 pos, float cloudZ) {
            // Slight anisotropy: flatter in Z, matches “billboard slab” feeling
            float3 q = float3(pos.xy * 0.75, pos.z * 0.25) + float3(0.0, 0.0, cloudZ * 0.001);

            float base = fbmFast(q * 0.85);

            float ridged = 1.0 - abs(2.0 * noise3(q * 2.2 + float3(7.3, 1.1, 3.7)) - 1.0);

            float dens = smoothstep(0.33, 0.82, base) * smoothstep(0.12, 0.95, ridged);

            // Kept to preserve the current “puffy” contrast. (This is still cheaper than extra ray steps.)
            dens = pow(dens, 1.35);

            return dens;
        }

        float phaseHG(float g, float mu) {
            float gg = g * g;
            float denom = pow(max(1.0 + gg - 2.0 * g * mu, 1e-3), 1.5);
            return (1.0 - gg) / (4.0 * 3.14159265 * denom);
        }

        float4 integrateCloud(float3 rayEnter,
                              float3 rayExit,
                              float3 viewDir,
                              float3 sunDir,
                              float cloudZ,
                              float slabHalf,
                              float2 uvForJitter)
        {
            float3 acc = float3(0.0);
            float alpha = 0.0;

            // Lighting (very cheap; no extra density samples)
            float mu = clamp(dot(-viewDir, sunDir), -1.0, 1.0);
            float phase = phaseHG(0.55, mu);

            float bright = mix(0.15, 1.0, saturate(phase * 6.0));
            float3 col = mix(float3(1.0), float3(1.0, 0.95, 0.9), saturate(phase * 6.0)) * bright;

            // IMPORTANT: looking upward used to be worst-case.
            // This makes overhead cheaper while keeping horizon reasonably smooth.
            float pitch = clamp(abs(viewDir.y), 0.0, 1.0);
            float overhead = smoothstep(0.55, 0.95, pitch);

            // Fewer steps overhead; more steps near horizon.
            float stepsF = mix(16.0, 10.0, overhead);
            int stepCount = int(stepsF);

            // Per-fragment jitter to hide banding when stepCount is reduced.
            float jitter = hash21(floor(uvForJitter * 512.0) + float2(cloudZ * 0.01, slabHalf * 19.0)) - 0.5;

            for (int i = 0; i < stepCount; ++i) {
                float t = (float(i) + 0.5 + jitter) / float(stepCount);
                t = clamp(t, 0.0, 1.0);

                float3 p = mix(rayEnter, rayExit, t);

                float dens = densityAt(p, cloudZ) * densityMul;
                if (dens < 0.002) { continue; }

                // Beer-Lambert-ish alpha per step
                float a = 1.0 - exp(-dens * 1.45);

                a *= (1.0 - alpha);

                acc += col * a;
                alpha += a;

                if (alpha > 0.985) { break; }
            }

            return float4(acc, alpha);
        }

        #pragma body
        
        // --- Body --------------------------------------------------------------

        float2 uv = _surface.diffuseTexcoord;
        float2 p2 = uv * 2.0 - 1.0;

        // Circular mask: discard outside the puff
        if (dot(p2, p2) > 1.0) {
            discard_fragment();
        }

        float slabHalf = slab_half;
        float3 camPos = scn_frame.inverseViewTransform[3].xyz;
        float3 worldPos = _surface.position;

        float3 viewDir = normalize(worldPos - camPos);
        float3 sDir = normalize(sun_dir);

        float3 rayEnter = worldPos - viewDir * slabHalf;
        float3 rayExit  = worldPos + viewDir * slabHalf;

        float4 res = integrateCloud(rayEnter, rayExit, viewDir, sDir, cloud_z, slabHalf, uv);

        float3 outCol = res.rgb;
        float a = clamp(res.a, 0.0, 1.0);

        if (shadow_only > 0.5) {
            _output.color = float4(a, a, a, a);
        } else {
            if (dither_depth > 0.5) {
                // Dither alpha -> binary coverage, so depth write becomes useful and overdraw collapses.
                float2 ip = floor(uv * 512.0);
                float rnd = hash21(ip + float2(cloud_z * 0.01, slab_half * 19.0));

                if (a < rnd) {
                    discard_fragment();
                }

                _output.color = float4(outCol, 1.0);
            } else {
                _output.color = float4(outCol, a);
            }
        }
        """
    }()

    static func makeMaterial(kind: Kind, slabHalf: Float, shadowOnlyProxy: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true

        let wantsDitherDepth: Bool = {
            if shadowOnlyProxy { return false }
            return (UserDefaults.standard.object(forKey: kDefaultsDitherDepthWrite) as? Bool) ?? true
        }()

        if wantsDitherDepth {
            // No blending, depth writes ON, alpha handled via discard (dither).
            material.blendMode = .replace
            material.writesToDepthBuffer = true
            material.transparencyMode = .singleLayer
        } else {
            // Old behaviour: blended alpha, no depth writes.
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            material.transparencyMode = .aOne
        }

        material.shaderModifiers = [
            .fragment: fragmentSource
        ]

        // Defaults; engine can override at runtime.
        material.setValue(NSNumber(value: 0.0), forKey: kCloudZ)
        material.setValue(NSNumber(value: slabHalf), forKey: kSlabHalf)
        material.setValue(NSNumber(value: 1.0), forKey: kDensityMul)
        material.setValue(SCNVector3(0.35, 0.9, 0.2), forKey: kSunDir)
        material.setValue(NSNumber(value: shadowOnlyProxy ? 1.0 : 0.0), forKey: kShadowOnly)
        material.setValue(NSNumber(value: wantsDitherDepth ? 1.0 : 0.0), forKey: kDitherDepth)

        return material
    }


    // Compatibility overload for older call sites that still provide billboard size + quality + sun direction.
    // Internally maps to the slab-based material builder.
    @MainActor
    static func makeMaterial(
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        quality: Double = 0.6,
        sunDir: simd_float3 = simd_float3(0, 1, 0)
    ) -> SCNMaterial {
        // Map billboard size -> a reasonable slab thickness.
        // This keeps the "volume" looking plausibly 3D without going insane on step count.
        let baseHalf = Float(max(0.001, min(halfWidth, halfHeight)))
        let slabHalf = max(0.6, min(baseHalf * 0.18, 450.0))

        let m = makeMaterial(kind: .volumetricBillboard, slabHalf: slabHalf, shadowOnlyProxy: false)

        // Seed a couple of uniforms so first frame isn't "all zeros" if update code runs later.
        m.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: kSunDir)
        m.setValue(NSNumber(value: 1.0), forKey: kDensityMul)

        // `quality` is accepted to keep API compatibility. If the shader later reads a quality uniform,
        // this is the natural place to set it.
        _ = quality

        return m
    }

}
