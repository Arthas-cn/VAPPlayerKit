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

/// 视频底图的 RGB/Alpha 采样矩形、模式和 YCbCr 矩阵。
struct VPKFrameUniforms {
    float4 rgbRect;
    float4 alphaRect;
    uint colorMatrix;
    uint alphaEnabled;
    uint2 padding;
};

/// 动态槽位顶点 / fragment 共用的画布矩形、mask 区域、旋转和 source UV 窗口。
struct VPKAttachmentUniforms {
    float4 renderRect;
    float4 maskRect;
    float4 rgbRect;
    float2 sourceUVOrigin;
    float2 sourceUVSize;
    uint rotation;
    uint colorMatrix;
    uint2 padding;
};

struct VPKAttachmentVertexOut {
    float4 position [[position]];
    float2 sourceCoordinate;
    float2 maskCoordinate;
    float2 canvasCoordinate;
};

/// 按 BT.601 (`colorMatrix == 0`) 或 BT.709 把 NV12 转 RGB。输入已减去 video-range 偏移。
float3 vpk_yuv_to_rgb(texture2d<float> yTexture,
                      texture2d<float> uvTexture,
                      sampler textureSampler,
                      float2 coordinate,
                      uint colorMatrix) {
    float y = yTexture.sample(textureSampler, coordinate).r - (16.0 / 255.0);
    float2 uv = uvTexture.sample(textureSampler, coordinate).rg - float2(0.5, 0.5);
    if (colorMatrix == 0) {
        return float3(
            1.164 * y + 1.596 * uv.y,
            1.164 * y - 0.392 * uv.x - 0.813 * uv.y,
            1.164 * y + 2.017 * uv.x
        );
    }
    return float3(
        1.164 * y + 1.793 * uv.y,
        1.164 * y - 0.213 * uv.x - 0.533 * uv.y,
        1.164 * y + 2.112 * uv.x
    );
}

/// 普通视频采样完整 RGB 并输出不透明像素；VAP 按 vapc 的真实区域拆分 RGB/Alpha。
fragment float4 vpk_fragment(
    VPKVertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant VPKFrameUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 rgbCoordinate = uniforms.rgbRect.xy + in.texCoord * uniforms.rgbRect.zw;
    float2 alphaCoordinate = uniforms.alphaRect.xy + in.texCoord * uniforms.alphaRect.zw;
    float3 rgb = saturate(vpk_yuv_to_rgb(
        yTexture, uvTexture, linearSampler, rgbCoordinate, uniforms.colorMatrix
    ));
    if (uniforms.alphaEnabled == 0) {
        return float4(rgb, 1.0);
    }
    float alphaY = yTexture.sample(linearSampler, alphaCoordinate).r;
    float alpha = saturate((alphaY - (16.0 / 255.0)) * (255.0 / 219.0));
    return float4(rgb * alpha, alpha);
}

/// 动态槽位四边形：把 renderRect 映射到 clip space，并按 maskRotation 旋转 mask 坐标。
vertex VPKAttachmentVertexOut vpk_attachment_vertex(
    uint vertexID [[vertex_id]],
    constant VPKAttachmentUniforms &uniforms [[buffer(0)]]
) {
    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    float2 corner = corners[vertexID];
    float2 canvas = uniforms.renderRect.xy + corner * uniforms.renderRect.zw;
    float2 maskCorner = corner;
    uint rotation = uniforms.rotation % 360;
    if (rotation == 90) {
        maskCorner = float2(1.0 - corner.y, corner.x);
    } else if (rotation == 180) {
        maskCorner = float2(1.0 - corner.x, 1.0 - corner.y);
    } else if (rotation == 270) {
        maskCorner = float2(corner.y, 1.0 - corner.x);
    }

    VPKAttachmentVertexOut out;
    out.position = float4(canvas.x * 2.0 - 1.0, 1.0 - canvas.y * 2.0, 0.0, 1.0);
    out.sourceCoordinate = uniforms.sourceUVOrigin + corner * uniforms.sourceUVSize;
    out.maskCoordinate = uniforms.maskRect.xy + maskCorner * uniforms.maskRect.zw;
    out.canvasCoordinate = canvas;
    return out;
}

/// 图片槽位打孔：只抠近黑 locator，保留彩色动画区域，供后续 overlay 混合。
fragment float4 vpk_attachment_punch_fragment(
    VPKAttachmentVertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant VPKAttachmentUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float maskY = yTexture.sample(linearSampler, in.maskCoordinate).r;
    float maskAlpha = saturate((maskY - (16.0 / 255.0)) * (255.0 / 219.0));
    float2 rgbCoordinate = uniforms.rgbRect.xy + in.canvasCoordinate * uniforms.rgbRect.zw;
    float3 rgb = saturate(vpk_yuv_to_rgb(
        yTexture, uvTexture, linearSampler, rgbCoordinate, uniforms.colorMatrix
    ));
    // 图片槽位把近黑 locator (B) 压在彩色动画 (A) 下。
    // 只抠 B，让后续 overlay 透出 A；不要打穿金色描边或发光。
    float peak = max(max(rgb.r, rgb.g), rgb.b);
    float locator = 1.0 - smoothstep(0.04, 0.12, peak);
    return float4(0.0, 0.0, 0.0, maskAlpha * locator);
}

/// 动态 overlay 正向混合：用 mask 的 Alpha 调制 source 纹理。
fragment float4 vpk_attachment_fragment(
    VPKAttachmentVertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> sourceTexture [[texture(2)]],
    constant VPKAttachmentUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 source = sourceTexture.sample(linearSampler, in.sourceCoordinate);
    float maskY = yTexture.sample(linearSampler, in.maskCoordinate).r;
    float maskAlpha = saturate((maskY - (16.0 / 255.0)) * (255.0 / 219.0));
    float3 rgb = source.rgb * step(1.0 / 255.0, source.a);
    return float4(rgb * maskAlpha, source.a * maskAlpha);
}
