//
//  TerrainShaders.metal
//  Glasslands
//
//  Created by . . on 9/29/25.
//

#include <metal_stdlib>
using namespace metal;

// Simple "glass tint" compute kernel that applies a mild sine warp and highlights.
kernel void glassTintKernel(
    texture2d<float, access::read>  inTexture  [[ texture(0) ]],
    texture2d<float, access::write> outTexture [[ texture(1) ]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = float2(gid) / float2(outTexture.get_width(), outTexture.get_height());

    float t = sin(uv.y * 40.0) * 0.002 + sin(uv.x * 30.0) * 0.002;
    float2 uv2 = clamp(uv + float2(t, -t), 0.0, 1.0);
    float4 c = inTexture.sample(s, uv2);

    // soft highlight
    float vignette = smoothstep(0.0, 0.6, distance(uv, float2(0.5)));
    float glow = 1.0 - vignette;
    c.rgb += glow * 0.05;

    outTexture.write(c, gid);
}
