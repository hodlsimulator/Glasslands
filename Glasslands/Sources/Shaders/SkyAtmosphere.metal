//
//  SkyAtmosphere.metal
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Simple analytic sky: Rayleigh + Mie single scattering, sun-only.
//  Designed for a skydome (inside-out sphere) with constant lighting model.
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

static constant float kPI = 3.14159265358979323846f;

inline float clamp01(float x){ return clamp(x, 0.0f, 1.0f); }

struct SkyUniforms {
    float4 sunDirWorld;   // xyz
    float4 sunTint;       // rgb
    float4 params0;       // x = turbidity (1..10), y = mieG (0..0.95), z = exposure, w = horizonLift
};

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};
struct VSOut {
    float4 position [[position]];
    float3 worldPos;
};

vertex VSOut sky_vertex(VSIn vin [[stage_in]],
                        constant SCNSceneBuffer& scn_frame [[buffer(0)]])
{
    VSOut o;
    float4 world = float4(vin.position, 1.0);
    float4 view  = scn_frame.viewTransform * world;
    o.position   = scn_frame.projectionTransform * view;
    o.worldPos   = world.xyz;
    return o;
}

// Phase functions
inline float phaseRayleigh(float mu) { return (3.0f / (16.0f * kPI)) * (1.0f + mu*mu); }
inline float phaseMieHG(float mu, float g) {
    float g2 = g*g;
    return (3.0f / (8.0f * kPI)) * ((1.0f - g2) * (1.0f + mu*mu)) / ((2.0f + g2) * pow(1.0f + g2 - 2.0f*g*mu, 1.5f));
}

fragment half4 sky_fragment(VSOut in [[stage_in]],
                            constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                            constant SkyUniforms& U [[buffer(1)]])
{
    // Camera position
    float4 camW4 = scn_frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / camW4.w;

    // View direction
    float3 V = normalize(in.worldPos - camPos);

    // Sun
    float3 sunW = normalize(U.sunDirWorld.xyz);
    float mu = clamp(dot(V, sunW), -1.0f, 1.0f);

    // Parameters
    float turbidity = clamp(U.params0.x, 1.0f, 10.0f);
    float mieG      = clamp(U.params0.y, 0.0f, 0.95f);
    float exposure  = max(0.0f, U.params0.z);
    float horizonK  = clamp(U.params0.w, 0.0f, 1.0f);

    // Coefficients (approximate)
    // Rayleigh (per-channel in 1/m)
    float3 betaR = float3(5.802e-6, 13.558e-6, 33.1e-6);
    // Mie scattering (scaled by turbidity)
    float  betaMScalar = 3.996e-6 * turbidity;
    float3 betaM = float3(betaMScalar);

    // Elevation above horizon: 0=horizon, 1=zenith.
    // Shape the ramp so haze collapses towards the horizon (clean zenith).
    float elev = clamp01(V.y);
    float e    = pow(elev, 0.35f);

    // Optical depth proxies.
    // - Rayleigh stays present up high for a deep blue.
    // - Mie collapses hard at zenith so the top sky stays clear.
    float hr = mix(3.0f, 1.0f, e);
    float hm = mix(6.5f, 0.06f, e);

    float3 Tr = exp(-betaR * hr * 1.0e4);       // transmittance
    float3 Tm = exp(-betaM * hm * 1.0e4);

    float PR = phaseRayleigh(mu);
    float PM = phaseMieHG(mu, mieG);

    float3 sunRGB = clamp(U.sunTint.rgb, 0.0f, 10.0f);

    // Scattered radiance (scaled; not physically exact, pleasing & fast)
    // Reduce Mie contribution as elevation rises (keeps zenith clean).
    float mieHeight = mix(1.0f, 0.12f, e);

    float3 Lr = sunRGB * PR * (1.0f - Tr);
    float3 Lm = sunRGB * PM * (1.0f - Tm) * 0.9f * mieHeight;

    float3 sky = Lr + Lm;

    // Horizon haze band: bright + slightly desaturated, confined low.
    // horizonK becomes a strength knob (0..1).
    float hazeBand = pow(1.0f - elev, 6.0f);
    float hazeK    = hazeBand * horizonK;
    float turb01   = clamp01((turbidity - 1.0f) / 9.0f);
    float hazeAmp  = (0.10f + 0.22f * turb01);
    sky += float3(0.85f, 0.90f, 1.00f) * (hazeK * hazeAmp);

    // Tone scale
    sky = 1.0f - exp(-sky * exposure);

    return half4(half3(clamp(sky, 0.0f, 1.0f)), half(1.0));
}
