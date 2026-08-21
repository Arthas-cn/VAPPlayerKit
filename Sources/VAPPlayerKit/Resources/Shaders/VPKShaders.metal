#include <metal_stdlib>
using namespace metal;

struct VPKVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VPKVertexOut vpk_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    VPKVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}

fragment float4 vpk_fragment(
    VPKVertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float y = yTexture.sample(linearSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(linearSampler, in.texCoord).rg - float2(0.5, 0.5);
    float3 rgb = float3(
        y + 1.402 * uv.y,
        y - 0.344136 * uv.x - 0.714136 * uv.y,
        y + 1.772 * uv.x
    );
    return float4(rgb, 1.0);
}
