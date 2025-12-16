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

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

  // MARK: - Uniform keys (SceneKit material values)

  static let kHalfWidth    = "u_halfWidth"
  static let kHalfHeight   = "u_halfHeight"
  static let kThickness    = "u_thickness"
  static let kDensityMul   = "u_densityMul"
  static let kPhaseG       = "u_phaseG"
  static let kSeed         = "u_seed"
  static let kHeightFade   = "u_heightFade"
  static let kEdgeFeather  = "u_edgeFeather"
  static let kBaseWhite    = "u_baseWhite"
  static let kLightGain    = "u_lightGain"
  static let kAmbient      = "u_ambient"
  static let kQuality      = "u_quality"
  static let kSunDir       = "u_sunDir"
  static let kPowderK      = "u_powderK"
  static let kEdgeLight    = "u_edgeLight"
  static let kBacklight    = "u_backlight"

  // MARK: - Shader modifier

  // Notes:
  // - Fragment shader modifier with `#pragma transparent` so SceneKit honours alpha output.
  // - Adds a screen-space LOD (via derivatives) so small/far puffs use fewer ray steps.
  //   This reduces worst-case zenith cost without changing the near/hero look.

  private static let shader: String = """
  #pragma transparent
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
  float  u_powderK;
  float  u_edgeLight;
  float  u_backlight;
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
    for (int i = 0; i < 3; i++) {
      v += a * noise3(p);
      p = p * 2.02 + float3(17.1, 3.2, 5.9);
      a *= 0.5;
    }
    return v;
  }

  inline float densityAt(
    float3 q,
    float3 anchor,
    float edgeFeather,
    float heightFade,
    float seed
  ) {
    float r = length(q);

    float3 p = q * 2.15 + anchor * 0.00125 + seed;

    float3 warp = float3(
      noise3(p * 0.65 + float3(10.0, 0.0, 0.0)),
      noise3(p * 0.65 + float3(0.0, 37.0, 0.0)),
      noise3(p * 0.65 + float3(0.0, 0.0, 91.0))
    );
    p += (warp - 0.5) * 0.85;

    float rimN = noise3(p * 1.35 + 7.1);
    float rw = r + (rimN - 0.5) * 0.14;

    float edge = 1.0 - smoothstep(1.0 - edgeFeather, 1.0, rw);

    float y01 = q.y * 0.5 + 0.5;
    y01 = clamp(y01 + (noise3(p * 0.90 + 5.7) - 0.5) * 0.08, 0.0, 1.0);

    float yFade = smoothstep(0.0, heightFade, y01) * (1.0 - smoothstep(1.0 - heightFade, 1.0, y01));
    float base = edge * yFade;
    if (base <= 0.0) { return 0.0; }

    float n1 = fbmFast(p);
    float n2 = fbmFast(p * 2.35 + 11.3);
    float n = mix(n1, n2, 0.45);

    float billow = 1.0 - abs(2.0 * noise3(p * 4.5 + 19.2) - 1.0);
    n = n + 0.18 * billow - 0.08 * (rimN - 0.5);

    float clumps = smoothstep(0.32, 0.82, n);
    return base * clumps;
  }

  #pragma body

  _output.color = float4(0.0);

  float2 uv = _surface.diffuseTexcoord;
  float2 q2 = (uv - float2(0.5, 0.5)) * 2.0;
  float r2 = length(q2);

  if (r2 > 1.02) {
    discard_fragment();
  } else {

    float uvMask = 1.0 - smoothstep(0.96, 1.02, r2);
    if (uvMask <= 0.0005) { discard_fragment(); }

    float3 ro = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;

    float3 rdView = normalize(_surface.position);
    float3 rd = normalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);

    float3 sunW = normalize(u_sunDir);
    float3 sunL = normalize((scn_node.inverseModelTransform * float4(sunW, 0.0)).xyz);

    float hw = max(0.001, u_halfWidth * 0.97);
    float hh = max(0.001, u_halfHeight * 0.97);

    float unit = max(hw, hh);
    float hz = max(0.001, u_thickness) * unit;

    float3 bmin = float3(-hw, -hh, -hz);
    float3 bmax = float3( hw,  hh,  hz);

    float3 t0s = (bmin - ro) / rd;
    float3 t1s = (bmax - ro) / rd;
    float3 tsm = min(t0s, t1s);
    float3 tsM = max(t0s, t1s);

    float t0 = max(max(tsm.x, tsm.y), tsm.z);
    float t1 = min(min(tsM.x, tsM.y), tsM.z);

    if (t1 <= max(t0, 0.0)) {
      discard_fragment();
    } else {

      float3 anchor = scn_node.modelTransform[3].xyz;

      // Base quality (author intent)
      float q = clamp(u_quality, 0.0, 1.0);
      float stepsHi = mix(12.0, 26.0, q);

      // Screen-space LOD: small/far puffs = larger UV derivatives => fewer steps.
      float2 du = dfdx(uv);
      float2 dv = dfdy(uv);
      float uvGrad = max(length(du), length(dv));

      // Tuned by eye: raise threshold if you see quality loss on mid-distance puffs.
      float lod = clamp((uvGrad - 0.0020) * 220.0, 0.0, 1.0);

      float stepsF = mix(stepsHi, 8.0, lod);
      int steps = int(stepsF);

      float tStart = max(t0, 0.0);
      float dt = (t1 - tStart) / max(1.0, stepsF);

      float jitter = fract(sin(dot(uv + float2(anchor.x, anchor.z) * 0.00007 + u_seed, float2(12.9898, 78.233))) * 43758.5453);
      float t = tStart + dt * jitter;

      float trans = 1.0;
      float3 col = float3(0.0);

      float stepU = dt / unit;
      float shadowStep = unit * 0.55;

      float g = clamp(u_phaseG, -0.95, 0.95);
      float mu = dot(rd, sunL);
      float vP = max(1.0 + g * g - 2.0 * g * mu, 1e-3);
      float denom = vP * sqrt(vP);
      float phase = ((1.0 - g * g) / denom) * 0.08;

      float3 baseWhite3 = float3(u_baseWhite);

      // Update shadow every N steps (more aggressive when puff is small)
      int shadowStride = (lod > 0.70) ? 4 : ((lod > 0.40) ? 3 : 2);
      float shadow = 1.0;

      for (int i = 0; i < 28; i++) {
        if (i >= steps) { break; }
        if (trans < 0.03) { break; }

        float3 p = ro + rd * t;
        float3 qv = float3(p.x / hw, p.y / hh, p.z / hz);

        float d = densityAt(qv, anchor, u_edgeFeather, u_heightFade, u_seed);

        if (d > 0.0005) {

          float sigma = d * u_densityMul;
          float a = 1.0 - exp(-sigma * stepU);

          if (a > 0.0001) {

            if ((i % shadowStride) == 0) {
              float3 sp = p + sunL * shadowStep;
              float3 sq = float3(sp.x / hw, sp.y / hh, sp.z / hz);
              float ds = densityAt(sq, anchor, u_edgeFeather, u_heightFade, u_seed * 1.37);
              shadow = exp(-ds * u_densityMul * 0.45);
            }

            float y01 = clamp((qv.y * 0.5) + 0.5, 0.0, 1.0);
            float amb = u_ambient * mix(0.62, 1.05, y01);

            float powder = 1.0 - exp(-sigma * u_powderK);
            float edge = clamp(d * u_edgeLight * 0.14, 0.0, 1.0);
            float back = pow(clamp(-mu, 0.0, 1.0), 2.0) * u_backlight;

            float light = amb + u_lightGain * shadow * phase;
            light *= (0.86 + powder * 0.14);
            light += edge * (0.18 + powder * 0.35) * shadow;
            light += back * edge * (0.25 + powder * 0.25);
            light = clamp(light, 0.0, 1.0);

            float3 sampleCol = baseWhite3 * light;

            col += trans * a * sampleCol;
            trans *= (1.0 - a);
          }
        }

        t += dt;
      }

      float alpha = 1.0 - trans;

      col = clamp(col, float3(0.0), float3(1.0));
      alpha = clamp(alpha, 0.0, 1.0);

      col *= uvMask;
      alpha *= uvMask;

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

    m.shaderModifiers = [.fragment: shader]

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

    m.setValue(NSNumber(value: 0.85 as Float), forKey: kPowderK)
    m.setValue(NSNumber(value: 3.0 as Float), forKey: kEdgeLight)
    m.setValue(NSNumber(value: 0.45 as Float), forKey: kBacklight)

    m.setValue(SCNVector3(sunDir.x, sunDir.y, sunDir.z), forKey: kSunDir)

    return m
  }

}
