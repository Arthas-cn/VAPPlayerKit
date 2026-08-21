#import <Foundation/Foundation.h>

static NSErrorDomain const VPKPlaybackErrorDomain = @"com.vapplayerkit.playback";

typedef NS_ENUM(NSInteger, VPKPlaybackErrorCode) {
    VPKPlaybackErrorCodeInvalidURL = 1,
    VPKPlaybackErrorCodeFileNotFound,
    VPKPlaybackErrorCodeInvalidMP4,
    VPKPlaybackErrorCodeInvalidVapc,
    VPKPlaybackErrorCodeUnsupportedCodec,
    VPKPlaybackErrorCodeDecoderCreationFailed,
    VPKPlaybackErrorCodeDecoderFailed,
    VPKPlaybackErrorCodeDynamicContentTimeout,
    VPKPlaybackErrorCodeMetalUnavailable,
    VPKPlaybackErrorCodeDrawableUnavailable,
    VPKPlaybackErrorCodeCancelled,
    VPKPlaybackErrorCodeAudioFailed
};
