#include <metal_stdlib>
using namespace metal;

/// 全屏三角形顶点输出。后续会按 alphaMode 改写 RGB / Alpha 采样坐标。
struct VPKVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// 覆盖整个 drawable 的 oversized triangle，避免额外 index buffer。
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

/// Phase 0 占位：BT.601 YUV->RGB。后续按 vapc 拆分 RGB/Alpha 区域并输出预乘 alpha。
///
/// 对照 `vap-master/iOS/QGVAPlayer/QGVAPlayer/Shaders`。
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
