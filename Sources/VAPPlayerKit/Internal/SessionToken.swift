import Foundation

/// 标识一次 PlaybackSession。parser / decode / dynamic / Metal 回调都必须携带并核对。
enum SessionToken: Equatable {
    case value(UInt64)

    /// 生成非 0 随机 token。新 session 递增/换新后，旧回调全部丢弃。
    static func make() -> SessionToken {
        .value(UInt64.random(in: 1...UInt64.max))
    }
}
