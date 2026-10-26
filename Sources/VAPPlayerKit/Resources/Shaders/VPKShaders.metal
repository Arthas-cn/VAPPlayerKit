#include <metal_stdlib>
using namespace metal;

/// 全屏三角形顶点输出。后续会按 alphaMode 改写 RGB / Alpha 采样坐标。
struct VPKVertexOut {
    /// 光栅化使用的裁剪空间位置。
    float4 position [[position]];
    /// 完整逻辑画布的归一化坐标，左上角为原点。
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
    /// 颜色区在完整编码帧中的归一化起点和尺寸。
    float4 rgbRect;
    /// 透明区在完整编码帧中的归一化起点和尺寸。
    float4 alphaRect;
    /// 0 选择 BT.601，其他值选择 BT.709。
    uint colorMatrix;
    /// 0 表示普通视频，非零表示采样独立透明区。
    uint alphaEnabled;
    /// 与 Swift 输入结构保持相同尾部对齐。
    uint2 padding;
};

/// 动态槽位顶点 / fragment 共用的画布矩形、mask 区域、旋转和 source UV 窗口。
struct VPKAttachmentUniforms {
    /// 动态槽位在逻辑画布中的归一化范围。
    float4 renderRect;
    /// 槽位遮罩在完整编码帧中的归一化范围。
    float4 maskRect;
    /// 颜色区在完整编码帧中的归一化范围。
    float4 rgbRect;
    /// 动态纹理可见窗口的起点，跑马灯会推进它。
    float2 sourceUVOrigin;
    /// 动态纹理可见窗口占整张纹理的比例。
    float2 sourceUVSize;
    /// 遮罩以度为单位的四分之一圈旋转。
    uint rotation;
    /// 视频颜色转换矩阵，与底图使用相同约定。
    uint colorMatrix;
    /// 与 Swift 输入结构保持相同尾部对齐。
    uint2 padding;
};

/// 动态槽位顶点传给 fragment 的插值坐标，不持有视频或纹理资源。
struct VPKAttachmentVertexOut {
    /// 动态四边形的裁剪空间位置。
    float4 position [[position]];
    /// 动态图片或文字纹理的采样坐标。
    float2 sourceCoordinate;
    /// 完整编码帧上的遮罩采样坐标。
    float2 maskCoordinate;
    /// 当前槽位对应的逻辑画布坐标，用于检查底图 locator。
    float2 canvasCoordinate;
};

/// 限制在线性滤波所属区域的实际 texel 中心之间，避免放大时混入区域外像素。
float2 vpk_region_coordinate(float2 coordinate, float4 region, float2 textureSize) {
    float2 lowerEdge = region.xy * textureSize;
    float2 upperEdge = (region.xy + region.zw) * textureSize;
    // 归一化 Float 往返最多引入约千分之一像素误差，不能把整数边界误扩成相邻 texel。
    lowerEdge = select(lowerEdge, round(lowerEdge), abs(lowerEdge - round(lowerEdge)) <= 0.001);
    upperEdge = select(upperEdge, round(upperEdge), abs(upperEdge - round(upperEdge)) <= 0.001);
    // UV 平面分辨率不同：保留覆盖区域的实际色度 texel；奇数边缘共享的色度不可再拆分。
    float2 firstCenter = floor(lowerEdge) + 0.5;
    float2 lastCenter = max(firstCenter, ceil(upperEdge) - 0.5);
    return clamp(coordinate * textureSize, firstCenter, lastCenter) / textureSize;
}

/// 分别限制 Y/UV 的区域采样，减去 video-range 偏移后按 BT.601 或 BT.709 转 RGB。
float3 vpk_yuv_to_rgb(texture2d<float> yTexture,
                      texture2d<float> uvTexture,
                      sampler textureSampler,
                      float2 coordinate,
                      float4 region,
                      uint colorMatrix) {
    float2 yCoordinate = vpk_region_coordinate(
        coordinate, region, float2(yTexture.get_width(), yTexture.get_height())
    );
    float2 uvCoordinate = vpk_region_coordinate(
        coordinate, region, float2(uvTexture.get_width(), uvTexture.get_height())
    );
    float y = yTexture.sample(textureSampler, yCoordinate).r - (16.0 / 255.0);
    float2 uv = uvTexture.sample(textureSampler, uvCoordinate).rg - float2(0.5, 0.5);
    // 素材声明 BT.601 时使用对应系数，不能固定套用高清矩阵。
    if (colorMatrix == 0) {
        return float3(
            1.164 * y + 1.596 * uv.y,
            1.164 * y - 0.392 * uv.x - 0.813 * uv.y,
            1.164 * y + 2.017 * uv.x
        );
    }
    // 其余已验证素材使用 BT.709，与 CPU 传入的 colorMatrix 约定一致。
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
        yTexture, uvTexture, linearSampler, rgbCoordinate, uniforms.rgbRect, uniforms.colorMatrix
    ));
    // 普通视频没有透明区；直接返回，避免对零尺寸 Alpha 矩形计算采样界限。
    if (uniforms.alphaEnabled == 0) {
        return float4(rgb, 1.0);
    }
    alphaCoordinate = vpk_region_coordinate(
        alphaCoordinate, uniforms.alphaRect, float2(yTexture.get_width(), yTexture.get_height())
    );
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
    // 旋转只影响遮罩坐标，不改变动态图片在逻辑画布的位置。
    if (rotation == 90) {
        maskCorner = float2(1.0 - corner.y, corner.x);
    } else if (rotation == 180) {
        // 半圈同时反转两个轴，保持 source 图片本身的方向。
        maskCorner = float2(1.0 - corner.x, 1.0 - corner.y);
    } else if (rotation == 270) {
        // 四分之三圈采用与 90 度相反的坐标交换。
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
        yTexture, uvTexture, linearSampler, rgbCoordinate, uniforms.rgbRect, uniforms.colorMatrix
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
