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

    // Historical/compat keys (some call sites still set these)
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
    static let kDebugSolid = "debugSolid"
    static let kCheapMode = "cheapMode"
    static let kDebugOutlierVis = "debugOutlierVis"
    static let kDebugCullOutlierCandidates = "debugCullOutlierCandidates"

    // Behaviour toggles (UserDefaults)
    // Default is OFF for smooth alpha clouds; can be re-enabled for depth-dither profiling.
    private static let kDefaultsDitherDepthWrite = "clouds.ditherDepthWrite"

    // Cached shader source (same for all materials; behaviour toggled via uniforms)
    private static let fragmentSource: String = {
        // SceneKit’s shader-modifier preprocessor is line-based.
        // Keeping explicit line breaks avoids `//` comments swallowing the rest of the shader.
        let lines: [String] = [
            "#pragma transparent",
            "#pragma arguments",
            "float cloud_z;",
            "float slab_half;",
            "float3 sun_dir;",
            "float shadow_only;",
            "float dither_depth;",
            "float densityMul;",
            "float phaseG;",
            "float ambient;",
            "float baseWhite;",
            "float lightGain;",
            "float powderK;",
            "float edgeLight;",
            "float backlight;",
            "float edgeFeather;",
            "float quality;",
            "float heightFade;",
            "float debugSolid;",
            "float cheapMode;",
            "float debugOutlierVis;",
            "float debugCullOutlierCandidates;",
            "",
            "#pragma declaration",
            "/* --- Hash / noise ------------------------------------------------------ */",
            "inline float hash11(float x) {",
            "    return fract(sin(x) * 43758.5453123);",
            "}",
            "inline float hash21(float2 p) {",
            "    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453123);",
            "}",
            "inline float noise3(float3 p) {",
            "    float3 i = floor(p);",
            "    float3 f = fract(p);",
            "    f = f * f * (3.0 - 2.0 * f);",
            "    float n = dot(i, float3(1.0, 57.0, 113.0));",
            "    float a = hash11(n + 0.0);",
            "    float b = hash11(n + 1.0);",
            "    float c = hash11(n + 57.0);",
            "    float d = hash11(n + 58.0);",
            "    float e = hash11(n + 113.0);",
            "    float g = hash11(n + 114.0);",
            "    float h = hash11(n + 170.0);",
            "    float j = hash11(n + 171.0);",
            "    float x1 = mix(a, b, f.x);",
            "    float x2 = mix(c, d, f.x);",
            "    float y1 = mix(x1, x2, f.y);",
            "    float x3 = mix(e, g, f.x);",
            "    float x4 = mix(h, j, f.x);",
            "    float y2 = mix(x3, x4, f.y);",
            "    return mix(y1, y2, f.z);",
            "}",
            "inline float fbmFast(float3 p) {",
            "    float v = 0.0;",
            "    float a = 0.5;",
            "    float3 q = p;",
            "    /* 3 octaves (kept for quality; overall cost is dominated by step count + overdraw) */",
            "    v += a * noise3(q);",
            "    q = q * 2.02 + 17.13;",
            "    a *= 0.5;",
            "    v += a * noise3(q);",
            "    q = q * 2.02 + 17.13;",
            "    a *= 0.5;",
            "    v += a * noise3(q);",
            "    return v;",
            "}",
            "inline float densityAt(float3 pos, float cloudZ) {",
            "    /* Slight anisotropy: flatter in Z, matches the billboard slab feeling */",
            "    float3 q = float3(pos.xy * 0.75, pos.z * 0.25) + float3(0.0, 0.0, cloudZ * 0.001);",
            "    float base = fbmFast(q * 0.85);",
            "    float ridged = 1.0 - abs(2.0 * noise3(q * 2.2 + float3(7.3, 1.1, 3.7)) - 1.0);",
            "    float dens = smoothstep(0.26, 0.82, base) * mix(1.0, smoothstep(0.10, 0.96, ridged), 0.02);",
            "    /* Softer contrast to reduce gritty stipple-like interior while keeping shape. */",
            "    dens = pow(dens, 0.86);",
            "    return dens;",
            "}",
            "inline float phaseHG(float g, float mu) {",
            "    float gg = g * g;",
            "    float denom = pow(max(1.0 + gg - 2.0 * g * mu, 1e-3), 1.5);",
            "    return (1.0 - gg) / (4.0 * 3.14159265 * denom);",
            "}",
            "inline float4 integrateCloud(",
            "    float3 rayEnter,",
            "    float3 rayExit,",
            "    float3 viewDir,",
            "    float3 sunDir,",
            "    float cloudZ,",
            "    float slabHalf,",
            " float2 uvForJitter,",
            " float densityMulLocal,",
            " float phaseGLocal,",
            " float ambientLocal,",
            " float baseWhiteLocal,",
            " float lightGainLocal,",
            " float powderKLocal,",
            " float edgeLightLocal,",
            " float backlightLocal,",
            " float qualityLocal",
            ") {",
            "    float3 acc = float3(0.0);",
            "    float alpha = 0.0;",
            "",
            "    /* Lighting (very cheap; no extra density samples) */",
            "    float mu = clamp(dot(-viewDir, sunDir), -1.0, 1.0);",
            "    float g = clamp(phaseGLocal, -0.2, 0.85);",
            "    float phase = phaseHG(g, mu);",
            "    float gain = max(0.01, lightGainLocal);",
            "    float phaseSat = clamp(phase * gain, 0.0, 1.0);",
            "    float bw = clamp(baseWhiteLocal, 0.0, 2.0);",
            "    float phaseSoft = sqrt(phaseSat);",
            "    float bright = mix(clamp(ambientLocal, 0.0, 1.0), 1.0, phaseSoft);",
            "    bright = bright * 0.94 + 0.06;",
            "    float3 baseCol = float3(bw);",
            "    float3 warmCol = float3(bw, bw, bw);",
            "    float3 col = mix(baseCol, warmCol, phaseSoft) * bright;",
            "    /* Backlight when the sun is behind the view ray. */",
            "    col *= (1.0 + max(0.0, backlightLocal) * pow(clamp(-mu, 0.0, 1.0), 1.25));",
            "",
            "    /* Quality now directly controls fragment cost (adaptive LOD actually matters). */",
            "    float q = clamp(qualityLocal, 0.35, 1.00);",
            "    float pitch = clamp(abs(viewDir.y), 0.0, 1.0);",
            "    float overhead = smoothstep(0.55, 0.95, pitch);",
            "    float stepsBase = mix(6.0, 14.0, q);",
            "    float stepsF = mix(stepsBase, max(6.0, stepsBase * 0.60), overhead);",
            "    const int MAX_STEPS = 12; int stepCount = int(clamp(stepsF + 0.5, 5.0, float(MAX_STEPS)));",
            "",
            "    /* Per-fragment jitter to hide banding when stepCount is reduced. */",
            "    float jitter = (hash21(uvForJitter * 2048.0 + float2(cloudZ * 0.01, slabHalf * 19.0)) - 0.5) * 0.12;",
            "",
            "    for (int i = 0; i < MAX_STEPS; ++i) { if (i >= stepCount) { break; }",
            "        float t = (float(i) + 0.5 + jitter) / float(stepCount);",
            "        t = clamp(t, 0.0, 1.0);",
            "        float3 p = mix(rayEnter, rayExit, t);",
            "        float dens = densityAt(p, cloudZ) * densityMulLocal;",
            "        float densCutoff = mix(0.006, 0.0015, q);",
            "        if (dens < densCutoff) {",
            "            continue;",
            "        }",
            "        /* Beer-Lambert-ish alpha per step */",
            "        float a = 1.0 - exp(-dens * 0.98);",
            "        float powder = 0.0;",
            "        float edge = 0.0;",
            "        a *= (1.0 - alpha);",
            "        acc += col * 1.06 * a;",
            "        alpha += a;",
            "        float alphaStop = mix(0.958, 0.988, q);",
            "        if (alpha > alphaStop) {",
            "            break;",
            "        }",
            "    }",
            "    return float4(acc, alpha);",
            "}",
            "",
            "#pragma body",
            "float2 uv = _surface.diffuseTexcoord;",
            "float2 p2 = uv * 2.0 - 1.0;",
            "",
            "/* Circular mask + soft feather to hide the quad */",
            "float r2 = dot(p2, p2);",
            "if (r2 > 1.0) {",
            "    discard_fragment();",
            "}",
            "float r = sqrt(r2);",
            "float ef = clamp(edgeFeather, 0.001, 0.45);",
            "float edgeMask = 1.0 - smoothstep(1.0 - ef, 1.0, r);",
            "edgeMask = pow(clamp(edgeMask, 0.0, 1.0), 1.08);",
            "float viewDist = length(_surface.position);",
            "",
            "float slabHalf = slab_half;",
            "",
            "if (debugSolid > 0.5) {",
            "    float aDbg = edgeMask * 0.92;",
            "    if (dither_depth > 0.5) {",
            "        float2 ipDbg = floor(uv * 512.0);",
            "        float rndDbg = hash21(ipDbg + float2(cloud_z * 0.01, slab_half * 19.0));",
            "        if (aDbg < rndDbg) {",
            "            discard_fragment();",
            "        }",
            "        _output.color = float4(1.0, 1.0, 1.0, 1.0);",
            "    } else {",
            "        _output.color = float4(1.0, 1.0, 1.0, aDbg);",
            "    }",
            "} else if (cheapMode > 0.5) {",
            "    float sunAmt = clamp(dot(normalize(float3(0.0, 1.0, 0.0)), normalize(sun_dir)) * 0.5 + 0.5, 0.0, 1.0);",
            "    float shade = mix(clamp(ambient, 0.0, 1.0), 1.0, pow(sunAmt, 0.42));",
            "    float n0 = hash21(uv * 1536.0 + float2(cloud_z * 0.013, slab_half * 7.1));",
            "    float n1 = hash21(uv * 4096.0 + float2(cloud_z * 0.021, slab_half * 13.7));",
            "    float shapeNoise = clamp(n0 * 0.68 + n1 * 0.32, 0.0, 1.0);",
            "    float radial = 1.0 - r;",
            "    float core = pow(smoothstep(0.10, 0.98, radial), 0.62);",
            "    float feather = pow(smoothstep(0.0, 1.0, edgeMask), 0.72);",
            "    float alphaBase = mix(0.62, 0.90, clamp(densityMul, 0.2, 1.4));",
            "    float dist01 = smoothstep(1600.0, 8200.0, viewDist);",
            "    float thicknessBoost = mix(1.0, 1.28, dist01) * mix(0.96, 1.10, clamp(slab_half / 220.0, 0.0, 1.0));",
            "    float aFast = clamp(core * feather * alphaBase * mix(0.95, 1.20, shapeNoise) * thicknessBoost, 0.0, 1.0);",
            "    float tint = clamp(baseWhite * shade, 0.0, 1.6);",
            "    float warm = clamp(dot(normalize(sun_dir), normalize(float3(0.2, 0.95, 0.25))), 0.0, 1.0);",
            "    float3 sunTint = mix(float3(1.0, 1.0, 1.0), float3(1.03, 1.01, 0.99), warm * 0.55);",
            "    float3 cFast = float3(tint) * sunTint * mix(0.96, 1.12, shapeNoise) * mix(1.0, 1.05, dist01);",
            "    if (dither_depth > 0.5) {",
            "        float2 ipFast = floor(uv * 512.0);",
            "        float rndFast = hash21(ipFast + float2(cloud_z * 0.01, slab_half * 19.0));",
            "        if (aFast < rndFast) {",
            "            discard_fragment();",
            "        }",
            "        _output.color = float4(clamp(cFast, 0.0, 1.0), 1.0);",
            "    } else {",
            "        float3 premulFast = clamp(cFast, 0.0, 1.0) * aFast;",
            "        _output.color = float4(premulFast, aFast);",
            "    }",
            "} else {",
            "/* _surface.position is view-space in SceneKit shader modifiers. */",
            "/* Convert to world-space position + world-space view ray using scn_node transforms. */",
            "/* Avoids scn_frame dependency and avoids view/world mixing. */",
            "float3 posView = _surface.position;",
            "float3 localPos = (scn_node.inverseModelViewTransform * float4(posView, 1.0)).xyz;",
            "float3 worldPos = (scn_node.modelTransform * float4(localPos, 1.0)).xyz;",
            "",
            "float3 rdView = normalize(posView);",
            "float3 rdLocal = normalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);",
            "float3 viewDir = normalize((scn_node.modelTransform * float4(rdLocal, 0.0)).xyz);",
            "float3 sDir = normalize(sun_dir);",
            "",
            "float3 rayEnter = worldPos - viewDir * slabHalf;",
            "float3 rayExit = worldPos + viewDir * slabHalf;",
            "",
            "float4 res = integrateCloud(",
            "    rayEnter, rayExit, viewDir, sDir, cloud_z, slabHalf, uv,",
            "    densityMul, phaseG, ambient, baseWhite, lightGain, powderK, edgeLight, backlight, quality",
            ");",
            "float3 outCol = res.rgb;",
            "float a = clamp(res.a, 0.0, 1.0);",
            "if ((outCol.x != outCol.x) || (outCol.y != outCol.y) || (outCol.z != outCol.z) || (a != a)) {",
            "    outCol = float3(0.0);",
            "    a = 0.0;",
            "}",
            "outCol *= edgeMask;",
            "a *= edgeMask;",
            "",
            "if (shadow_only > 0.5) {",
            "    _output.color = float4(a, a, a, a);",
            "} else {",
            "    float farFrag = smoothstep(3200.0, 10500.0, viewDist);",
            "    float lum = dot(outCol, float3(0.299, 0.587, 0.114));",
            "    float proj = slab_half / max(1.0, viewDist);",
            "    float cmax = max(outCol.x, max(outCol.y, outCol.z));",
            "    float cmin = min(outCol.x, min(outCol.y, outCol.z));",
            "    float chroma = cmax - cmin;",
            "    float outlierScore = farFrag",
            "        * (1.0 - smoothstep(0.012, 0.040, proj))",
            "        * smoothstep(0.050, 0.190, a)",
            "        * (1.0 - smoothstep(0.015, 0.040, chroma))",
            "        * (1.0 - smoothstep(0.20, 0.36, lum));",
            "    if (debugOutlierVis > 0.5 && outlierScore > 0.60) {",
            "        _output.color = float4(1.0, 0.15, 0.0, 1.0);",
            "    } else {",
            "        float cullThreshold = (debugCullOutlierCandidates > 0.5) ? 0.60 : 0.82;",
            "        if (outlierScore > cullThreshold) {",
            "            discard_fragment();",
            "        }",
            "    float minAlpha = mix(0.0, 0.085, farFrag);",
            "    if (a < minAlpha) {",
                "        discard_fragment();",
            "    }",
            "    if (dither_depth > 0.5) {",
            "        /* Dither alpha -> binary coverage, so depth write becomes useful and overdraw collapses. */",
            "        float2 ip = floor(uv * 512.0);",
            "        float rnd = hash21(ip + float2(cloud_z * 0.01, slab_half * 19.0));",
            "        if (a < rnd) {",
            "            discard_fragment();",
            "        }",
            "        _output.color = float4(clamp(outCol, 0.0, 1.0), 1.0);",
            "    } else {",
            "        float3 premul = clamp(outCol, 0.0, 1.0);",
            "        _output.color = float4(premul, a);",
            "    }",
            "    }",
            "}",
            "}"
        ]

        return lines.joined(separator: "\n")
    }()

    static func makeMaterial(kind: Kind, slabHalf: Float, shadowOnlyProxy: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true

        let composite = ProcessInfo.processInfo.environment["CLOUD_COMPOSITE"]?.lowercased()
        let wantsDitherDepth: Bool = {
            if shadowOnlyProxy {
                return false
            }
            if composite == "dither" {
                return true
            }
            if composite == "blend" {
                return false
            }
            return (UserDefaults.standard.object(forKey: kDefaultsDitherDepthWrite) as? Bool) ?? false
        }()

        if wantsDitherDepth {
            // No blending, depth writes ON, alpha handled via discard (dither).
            material.blendMode = .replace
            material.writesToDepthBuffer = true
            material.transparencyMode = .singleLayer
        } else {
            // Smooth alpha path (no dither stipple).
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            material.transparencyMode = .aOne
        }

        material.shaderModifiers = [.fragment: fragmentSource]
        dumpFragmentSourceIfNeeded(kind: "\(kind)", source: fragmentSource)
        let forceDebugSolid = (ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_FORCE_SOLID"] == "1")

        // Defaults; engine can override at runtime.
        material.setValue(NSNumber(value: 0.0), forKey: kCloudZ)
        material.setValue(NSNumber(value: slabHalf), forKey: kSlabHalf)
        material.setValue(NSNumber(value: Float(1.0)), forKey: kDensityMul)
        material.setValue(SCNVector3(0.35, 0.9, 0.2), forKey: kSunDir)
        material.setValue(NSNumber(value: shadowOnlyProxy ? 1.0 : 0.0), forKey: kShadowOnly)
        material.setValue(NSNumber(value: wantsDitherDepth ? 1.0 : 0.0), forKey: kDitherDepth)
        material.setValue(NSNumber(value: forceDebugSolid ? 1.0 : 0.0), forKey: kDebugSolid)
        material.setValue(NSNumber(value: Float(0.0)), forKey: kCheapMode)
        material.setValue(NSNumber(value: (ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_OUTLIER_VIS"] == "1") ? Float(1.0) : Float(0.0)), forKey: kDebugOutlierVis)
        material.setValue(NSNumber(value: (ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_CULL_OUTLIERS"] == "1") ? Float(1.0) : Float(0.0)), forKey: kDebugCullOutlierCandidates)

        // Visual defaults (engine can override via applyCloudSunUniforms()).
        material.setValue(NSNumber(value: Float(0.60)), forKey: kPhaseG)
        material.setValue(NSNumber(value: Float(0.36)), forKey: kAmbient)
        material.setValue(NSNumber(value: Float(1.0)), forKey: kBaseWhite)
        material.setValue(NSNumber(value: Float(3.35)), forKey: kLightGain)
        material.setValue(NSNumber(value: Float(0.85)), forKey: kPowderK)
        material.setValue(NSNumber(value: Float(3.0)), forKey: kEdgeLight)
        material.setValue(NSNumber(value: Float(0.45)), forKey: kBacklight)
        material.setValue(NSNumber(value: Float(0.26)), forKey: kEdgeFeather)

        #if DEBUG
        if ProcessInfo.processInfo.environment["CLOUD_DIAG"] == "1", forceDebugSolid {
            NSLog("[CLOUD_DIAG] GL_DEBUG_CLOUD_FORCE_SOLID=1 active")
        }
        #endif

        _ = kind
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

        // Seed a couple of uniforms so first frame isn't all zeros if update code runs later.
        m.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: kSunDir)
        m.setValue(NSNumber(value: Float(1.0)), forKey: kDensityMul)

        // `quality` is accepted to keep API compatibility.
        _ = quality
        return m
    }

    private static func dumpFragmentSourceIfNeeded(kind: String, source: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CLOUD_DIAG"] == "1" else { return }
        do {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let url = dir.appendingPathComponent("cloud_fragment_\(kind).metal")
            try source.write(to: url, atomically: true, encoding: .utf8)
            NSLog("[CLOUD_DIAG] dumped fragment source to \(url.path)")
        } catch {
            NSLog("[CLOUD_DIAG] failed to dump fragment source: \(String(describing: error))")
        }
        #endif
    }
}
