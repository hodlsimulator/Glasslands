//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Camera-anchored volumetric clouds on the inside of a sphere.
//  Fragment-only shader modifier:
//   • Base density from equirect coverage (same impostor logic as billboards)
//   • FBM domain jitter
//   • Single scattering with HG phase, powder effect, horizon lift
//   • HDR sun drawn into the sky and dimmed by cloud transmittance
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        // ---------- arguments ----------
        #pragma arguments
        texture2d<float> coverageTex;
        sampler          coverageTexSampler;

        float3 sunDirView;
        float3 sunTint;
        float3 skyZenith;
        float3 skyHorizon;
        float  sunEDRCore;

        float2 wind;
        float  time;

        float  coverage;      // 0..1
        float  densityMul;    // master density
        float  stepMul;       // 0.7..1.5
        float  horizonLift;   // horizon boost

        // ---------- helpers (declare BEFORE body) ----------
        float  hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            float h = dot(p, p + float2(78.233, 78.233));
            p += float2(h, h);
            return fract(p.x * p.y);
        }

        float  vnoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            float a = hash21(i);
            float b = hash21(i + float2(1.0,0.0));
            float c = hash21(i + float2(0.0,1.0));
            float d = hash21(i + float2(1.0,1.0));
            float2 u = f*f*(3.0 - 2.0*f);
            return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
        }

        float  fbm2(float2 p) {
            float a = 0.5, f = 1.0, s = 0.0;
            s += a * vnoise(p * f); a *= 0.5; f *= 2.03;
            s += a * vnoise(p * f);
            return s;
        }

        float3 screenAdd(float3 base, float3 add) { return base + add - base * add; }

        // ---------- body ----------
        #pragma body

        // March along opposite of view vector (towards sky)
        float3 rd = normalize(-_surface.view);
        float3 sunV = normalize(sunDirView);

        // Direction → equirect UV
        const float INV_TAU = 0.15915494309189535;   // 1/(2*pi)
        const float INV_PI  = 0.3183098861837907;    // 1/pi
        float u = 0.5 + atan2(rd.x, rd.z) * INV_TAU;
        float v = 0.5 - asin(rd.y) * INV_PI;

        // Base sky gradient
        float tSky = clamp(rd.y * 0.62 + 0.30, 0.0, 1.0);
        float3 col = mix(skyHorizon, skyZenith, tSky);

        // HDR sun (disc + halos) added to clear sky
        float ct   = clamp(dot(rd, sunV), -1.0, 1.0);
        float ang  = acos(ct);
        const float rad = 0.95 * 0.017453292519943295;
        float core  = 1.0 - smoothstep(rad*0.75, rad,       ang);
        float halo1 = 1.0 - smoothstep(rad*1.25, rad*3.50,  ang);
        float halo2 = 1.0 - smoothstep(rad*3.50, rad*7.50,  ang);
        float edr   = core * sunEDRCore + halo1 * 0.90 + halo2 * 0.25;
        float3 sunCol = sunTint * edr;

        // Gentle advection (explicit vector construction)
        float2 flow = float2(time, time) * wind;
        float2 uv0  = float2(fract(u + flow.x), clamp(v + flow.y * 0.25, 0.001, 0.999));

        // March settings
        int   N  = (int)(32.0 * clamp(stepMul, 0.7, 1.5)); // 22..48
        float T  = 1.0;                 // transmittance
        float3 S = float3(0.0, 0.0, 0.0); // single scattering

        // HG phase
        float mu    = clamp(dot(rd, sunV), -1.0, 1.0);
        float g     = 0.62;
        float phase = (1.0 - g*g) / pow(1.0 + g*g - 2.0*g*mu, 1.5);
        phase = clamp(phase, 0.0, 5.0);

        // Coverage→threshold (lenient so clouds show)
        float thresh   = clamp(0.55 - 0.35 * clamp(coverage, 0.0, 1.0), 0.20, 0.62);
        float softness = 0.28;

        for (int i = 0; i < N; ++i) {
            float t = (float(i) + 0.5) / float(N);
            float h = t;

            // Vertical envelope
            float env = smoothstep(0.06, 0.40, h) * (1.0 - smoothstep(0.48, 0.98, h));

            // Domain warp (scalar→vector made explicit)
            float2 j = float2(
                hash21(uv0 * 13.0 + float2(t, t)),
                hash21(uv0 * 19.0 + float2(t*1.77, t*1.77))
            );
            float s = fbm2(uv0 * 3.2 + j) * 0.004;
            float2 off = (j - float2(0.5, 0.5)) * 0.006 + float2(s, s);

            float2 uvS = fract(uv0 + off);
            float dBase = coverageTex.sample(coverageTexSampler, uvS).r;

            // Fluffy silhouette
            float d = smoothstep(thresh - softness, thresh + softness, dBase);

            // Powder effect
            float powder = 1.0 - exp(-2.2 * d);

            // Slice extinction + scattering
            float dens  = max(0.0, d * env * densityMul * 1.25);
            float sigma = 1.2 / float(N);
            float A = sigma * dens;
            float a = exp(-A);
            float sliceT = T * (1.0 - a);

            float3 scatCol = sunTint * (phase * (0.40 + 0.60 * powder));
            S += scatCol * sliceT;

            T *= a;
            if (T < 0.02) { break; }
        }

        // Sun dimmed by cloud transmittance + in-cloud light + horizon lift
        col = screenAdd(col, sunCol * T);
        col += S;
        col += float3(horizonLift * clamp(1.0 - tSky, 0.0, 1.0) * 0.35);

        _output.color = float4(col, 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Defaults
        m.setValue(SCNVector3(0, 1, 0),            forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82),   forKey: "sunTint")
        m.setValue(SCNVector3(0.10, 0.28, 0.65),   forKey: "skyZenith")
        m.setValue(SCNVector3(0.55, 0.72, 0.94),   forKey: "skyHorizon")
        m.setValue(7.5 as CGFloat,                 forKey: "sunEDRCore")

        m.setValue(SCNVector3(6.0, 2.0, 0.0),      forKey: "wind")
        m.setValue(0.0 as CGFloat,                 forKey: "time")

        m.setValue(0.45 as CGFloat,                forKey: "coverage")
        m.setValue(1.35 as CGFloat,                forKey: "densityMul")
        m.setValue(1.10 as CGFloat,                forKey: "stepMul")
        m.setValue(0.18 as CGFloat,                forKey: "horizonLift")

        return m
    }
}
