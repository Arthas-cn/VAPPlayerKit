import Foundation

/// 真机宿主测试复用 Demo 的正式本地素材；SPM 测试仍使用各自生成的 Bundle.module。
extension Bundle {
    /// TEST_HOST 进程的 App Bundle，包含 Tests/Fixtures/VAP 的资源副本。
    static var module: Bundle { .main }
}
