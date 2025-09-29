//
//  TerrainShaders.metal
//  Glasslands
//
//  Created by . . on 9/29/25.
//

#include <metal_stdlib>
using namespace metal;

// Simple "glass tint" compute kernel that applies a mild sine warp and highlight.
// Uses manual bilinear sampling via texture.read(...) to avoid sampler() usage
// in compute (which triggered the 'no member named sample' error).

inline float4 bilinearRead(texture2d<float, access::read> tex, float2 uv)
{
    const float2 size = float2(tex.get_width(), tex.get_height());

    // Convert 0..1 UV -> pixel space, center texels at half integers
    float2 p = uv * size - 0.5f;

    float2 p0f = floor(p);
    float2 frac = p - p0f;

    int2 p0 = int2(p0f);
    int2 p1 = p0 + int2(1, 1);

    // Clamp integer coords into valid range
    int2 maxC = int2((int)tex.get_width()  - 1,
                     (int)tex.get_height() - 1);
    p0 = clamp(p0, int2(0), maxC);
    p1 = clamp(p1, int2(0), maxC);

    // Neighbours
    float4 c00 = tex.read(uint2(p0.x, p0.y));
    float4 c10 = tex.read(uint2(p1.x, p0.y));
    float4 c01 = tex.read(uint2(p0.x, p1.y));
    float4 c11 = tex.read(uint2(p1.x, p1.y));

    // Lerp
    float4 cx0 = mix(c00, c10, frac.x);
    float4 cx1 = mix(c01, c11, frac.x);
    return mix(cx0, cx1, frac.y);
}

kernel void glassTintKernel(
    texture2d<float, access::read>   inTexture  [[ texture(0) ]],
    texture2d<float, access::write>  outTexture [[ texture(1) ]],
    uint2 gid [[thread_position_in_grid]]
)
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;

    // Normalised UV
    float2 uv = float2(gid) / float2(outTexture.get_width(), outTexture.get_height());

    // Small opposing sine warp
    float t = sin(uv.y * 40.0f) * 0.002f + sin(uv.x * 30.0f) * 0.002f;
    float2 uv2 = clamp(uv + float2(t, -t), 0.0f, 1.0f);

    // Read source with manual bilinear
    float4 c = bilinearRead(inTexture, uv2);

    // Soft highlight/vignette
    float vignette = smoothstep(0.0f, 0.6f, distance(uv, float2(0.5f)));
    float glow = 1.0f - vignette;
    c.rgb += glow * 0.05f;

    outTexture.write(c, gid);
}
