#import <Foundation/Foundation.h>

/// VAPPlayerKit Objective-C 错误域，与 Swift `VPKPlaybackErrorDomain` 字符串一致。
static NSErrorDomain const VPKPlaybackErrorDomain = @"com.vapplayerkit.playback";

/// 与 Swift `PlaybackErrorCode` 对齐的错误码。从 1 起，避免和 0/unknown 混淆。
typedef NS_ENUM(NSInteger, VPKPlaybackErrorCode) {
    /// URL 不是本地 file URL。
    VPKPlaybackErrorCodeInvalidURL = 1,
    /// 本地文件不存在。
    VPKPlaybackErrorCodeFileNotFound,
    /// MP4 容器非法。
    VPKPlaybackErrorCodeInvalidMP4,
    /// vapc 元数据非法。
    VPKPlaybackErrorCodeInvalidVapc,
    /// 设备不支持该 codec。
    VPKPlaybackErrorCodeUnsupportedCodec,
    /// 创建系统解码管线失败。
    VPKPlaybackErrorCodeDecoderCreationFailed,
    /// 解码运行失败。
    VPKPlaybackErrorCodeDecoderFailed,
    /// 动态内容超时。
    VPKPlaybackErrorCodeDynamicContentTimeout,
    /// Metal 不可用。
    VPKPlaybackErrorCodeMetalUnavailable,
    /// 当前拿不到 drawable。
    VPKPlaybackErrorCodeDrawableUnavailable,
    /// session 已取消。
    VPKPlaybackErrorCodeCancelled,
    /// 音频路径失败。
    VPKPlaybackErrorCodeAudioFailed
};
