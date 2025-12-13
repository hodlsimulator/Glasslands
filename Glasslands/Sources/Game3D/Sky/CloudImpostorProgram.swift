//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Shader-modifier impostor “volume” for clouds: a single SCNPlane that ray-marches
//  a cheap density field in view-facing local space.
//
//  This is intentionally self-contained (no SCNProgram) so it is easy to attach to any
//  SCNMaterial and keeps SceneKit’s pipeline simple.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

    static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.transparencyMode = .aOne

        // Fragment shader modifier: SceneKit replaces `_output.color` and allows uniforms
        // via `setValue(_:forKey:)`.
        m.shaderModifiers = [
            .fragment: fragmentModifier
        ]

        // Defaults are sane and get overridden by FirstPersonEngine.applyCloudSunUniforms().
        m.setValue(14.0 as CGFloat, forKey: "densityMul")
        m.setValue(5.6 as CGFloat, forKey: "thickness")
        m.setValue(-0.02 as CGFloat, forKey: "densBias")
        m.setValue(0.86 as CGFloat, forKey: "coverage")

        m.setValue(0.0036 as CGFloat, forKey: "puffScale")

        m.setValue(0.16 as CGFloat, forKey: "edgeFeather")
        m.setValue(0.07 as CGFloat, forKey: "edgeCut")
        m.setValue(0.18 as CGFloat, forKey: "edgeNoiseAmp")

        m.setValue(2.10 as CGFloat, forKey: "rimFeatherBoost")
        m.setValue(2.80 as CGFloat, forKey: "rimFadePow")

        m.setValue(1.05 as CGFloat, forKey: "shapeScale")
        m.setValue(0.42 as CGFloat, forKey: "shapeLo")
        m.setValue(0.70 as CGFloat, forKey: "shapeHi")
        m.setValue(2.15 as CGFloat, forKey: "shapePow")

        m.setValue(0.62 as CGFloat, forKey: "hgG")
        m.setValue(1.0 as CGFloat, forKey: "baseWhite")
        m.setValue(1.65 as CGFloat, forKey: "lightGain")
        m.setValue(1.0 as CGFloat, forKey: "hiGain")

        m.setValue(0.70 as CGFloat, forKey: "occK")

        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        return m
    }

    // MARK: - Shader modifier

    private static let fragmentModifier = #"""
    #pragma arguments
    float3 sunDirView;
    float densityMul;
    float thickness;
    float densBias;
    float coverage;

    float puffScale;

    float edgeFeather;
    float edgeCut;
    float edgeNoiseAmp;

    float rimFeatherBoost;
    float rimFadePow;

    float shapeScale;
    float shapeLo;
    float shapeHi;
    float shapePow;

    float hgG;
    float baseWhite;
    float lightGain;
    float hiGain;

    float occK;

    #pragma body

    // ------------------------------------------------------------
    // Very cheap hash / noise (no sin/cos in the hot path)
    // ------------------------------------------------------------

    float hash11(float p) {
        p = fract(p * 0.1031);
        p *= p + 33.33;
        p *= p + p;
        return fract(p);
    }

    float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.yzx + 33.33);
        return fract((p.x + p.y) * p.z);
    }

    float noise3(float3 x) {
        float3 i = floor(x);
        float3 f = fract(x);

        float3 u = f * f * (3.0 - 2.0 * f);

        float n000 = hash13(i + float3(0.0, 0.0, 0.0));
        float n100 = hash13(i + float3(1.0, 0.0, 0.0));
        float n010 = hash13(i + float3(0.0, 1.0, 0.0));
        float n110 = hash13(i + float3(1.0, 1.0, 0.0));
        float n001 = hash13(i + float3(0.0, 0.0, 1.0));
        float n101 = hash13(i + float3(1.0, 0.0, 1.0));
        float n011 = hash13(i + float3(0.0, 1.0, 1.0));
        float n111 = hash13(i + float3(1.0, 1.0, 1.0));

        float nx00 = mix(n000, n100, u.x);
        float nx10 = mix(n010, n110, u.x);
        float nx01 = mix(n001, n101, u.x);
        float nx11 = mix(n011, n111, u.x);

        float nxy0 = mix(nx00, nx10, u.y);
        float nxy1 = mix(nx01, nx11, u.y);

        return mix(nxy0, nxy1, u.z);
    }

    float fbm3(float3 p) {
        float f = 0.0;
        float a = 0.5;
        float3 pp = p;

        f += a * noise3(pp); pp = pp * 2.02 + 19.19; a *= 0.5;
        f += a * noise3(pp); pp = pp * 2.02 + 19.19; a *= 0.5;
        f += a * noise3(pp);

        return f;
    }

    float fbm3_billow(float3 p) {
        float f = 0.0;
        float a = 0.5;
        float3 pp = p;

        float n0 = noise3(pp); f += a * (1.0 - abs(2.0*n0 - 1.0)); pp = pp * 2.02 + 19.19; a *= 0.5;
        float n1 = noise3(pp); f += a * (1.0 - abs(2.0*n1 - 1.0)); pp = pp * 2.02 + 19.19; a *= 0.5;
        float n2 = noise3(pp); f += a * (1.0 - abs(2.0*n2 - 1.0));

        return f;
    }

    // ------------------------------------------------------------
    // Impostor local space & silhouette shaping
    // ------------------------------------------------------------

    float2 uv = _surface.diffuseTexcoord;

    // Convert [0..1] → [-1..1] with aspect correction so the puff stays round.
    float2 uvE = uv * 2.0 - 1.0;

    float impostorHalfW = 1.0;
    float impostorHalfH = 1.0;

    // SceneKit provides surface coordinate derivatives.
    float2 dudv = float2(length(dfdx(uvE)), length(dfdy(uvE)));
    float footprint = max(dudv.x, dudv.y);

    // Smooth elliptical edge mask (soft discard)
    float r = length(uvE);
    float cutR = max(0.0, 1.0 - edgeCut);
    float featherW = max(0.001, edgeFeather * max(0.5, rimFeatherBoost));

    // Add a subtle noisy edge to avoid perfect circles.
    float edgeN = fbm3(float3(uvE * 7.5, 1.7));
    float noisyCut = cutR + (edgeN - 0.5) * edgeNoiseAmp;

    float edgeMask = 1.0 - smoothstep(noisyCut, noisyCut + featherW, r);
    if (edgeMask <= 0.001) discard_fragment();

    // Interior vs rim factor for soft fades.
    float rimSoft = smoothstep(0.35, 1.0, r);

    // Macro breakup (keeps blue gaps inside the puff)
    float2 uvm = uvE * shapeScale;
    float m = noise3(float3(uvm * 2.4, 11.0));
    m = smoothstep(shapeLo, shapeHi, m);
    m = pow(max(m, 0.0), max(0.5, shapePow));
    float sMask = m;

    // ------------------------------------------------------------
    // Density field (cheap “volume” inside the plane)
    // ------------------------------------------------------------

    // Reduce the floor so puffs do not read as a uniform haze sheet.
    float coreFloorK = clamp(0.08 + 0.16 * coverage, 0.0, 0.38);

    // Adaptive detail boost based on pixel footprint (prevents shimmer)
    float detailBoost = clamp(1.0 / max(footprint, 0.002), 1.0, 8.0);

    float baseScale = puffScale * detailBoost;

    // Wider Z sampling yields better depth variation without more steps.
    const int NMAX = 5;
    float zLUT[NMAX] = { -0.55, -0.25, 0.0, 0.25, 0.55 };

    // View direction in “puff local” is +Z (camera looks down -Z in view space, but this is an impostor)
    // This march is purely along the impostor depth axis.
    float Lm = max(0.3, thickness);
    float stepMulLocal = 1.0;
    float dt = 0.0;

    // Choose a small fixed sample count based on on-screen size.
    float sizeT = clamp(1.0 - footprint * 6.0, 0.0, 1.0);
    int Ncalc = (sizeT > 0.60) ? 5 : ((sizeT > 0.30) ? 4 : 3);
    dt = Lm / float(Ncalc);

    // Henyey–Greenstein phase (approx)
    float cosVS = clamp(dot(normalize(-_surface.view), normalize(sunDirView)), -1.0, 1.0);
    float g = clamp(hgG, -0.85, 0.85);
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosVS;
    float phase = (1.0 - g2) / (4.0 * 3.14159265 * denom * sqrt(denom));

    // A cheap self-occlusion probe (two offset samples)
    float3 occP = float3(uvE * (baseScale * 360.0), 0.0);
    float occ1 = noise3(occP + float3(13.7, 3.1, 9.2));
    float occ2 = noise3(occP + float3(-9.4, 7.3, 4.6));
    float occ = clamp((occ1 + occ2) * 0.5, 0.0, 1.0);

    float Lvis = exp(-max(0.0, occK) * occ);

    // Scattering gain
    float S = baseWhite * lightGain * hiGain * phase * Lvis;

    // Extinction
    float sigmaS = max(0.0, densityMul) * 0.045;

    float alphaAcc = 0.0;
    float3 colAcc = float3(0.0);

    // ------------------------------------------------------------
    // Ray-march inside the impostor
    // ------------------------------------------------------------

    for (int si = 0; si < Ncalc; si++) {

        float z = zLUT[si];
        float3 p = float3(uvE * (baseScale * 360.0), z * (baseScale * 420.0));

        // Domain warps: cheap drift
        float w0 = fbm3(p * 0.35 + 11.0);
        float w1 = fbm3(p * 0.70 + 27.0);
        p.xy += (float2(w0, w1) - 0.5) * 1.25;

        // Core “cauliflower” + billow micro detail
        float core = fbm3(p * 0.75 + 3.0);
        float micro = fbm3_billow(p * 2.10 + 17.0);

        float d = clamp(core * 0.75 + micro * 0.55, 0.0, 1.0);

        // Apply silhouette and macro mask
        d = d * edgeMask * sMask;

        // Keep a small minimum near the centre so the puff does not hollow out.
        d = max(d, coreFloorK * edgeMask);

        // Non-linear density curve: thicker cores, airy edges
        float dC = clamp(d, 0.0, 1.0);
        float d15 = dC * sqrt(max(dC, 0.0));
        float rho = max(0.0, densBias + 0.22 * d15);

        float aStep = 1.0 - exp(-sigmaS * rho * dt);

        // Standard front-to-back compositing
        float T = 1.0 - alphaAcc;
        colAcc += T * (S * aStep);
        alphaAcc += T * aStep;

        if (alphaAcc > 0.995) break;
    }

    // Rim fade to keep the disc edges soft
    float rimFade = pow(1.0 - rimSoft, max(0.5, rimFadePow));
    alphaAcc *= (0.65 + 0.35 * rimFade);

    // Final colour: keep within bounds
    float3 C = min(colAcc, float3(1.0));

    _output.color = float4(C, clamp(alphaAcc, 0.0, 1.0));
    """#
}
