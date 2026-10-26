// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VAPPlayerKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [.library(name: "VAPPlayerKit", targets: ["VAPPlayerKit"])],
    targets: [
        .target(
            name: "VAPPlayerKit",
            resources: [.process("Resources")],
            // 解码、渲染和 UIKit 宿主都由系统框架提供，不引入下载或图片缓存依赖。
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit")
            ]
        ),
        // 真机无法读取构建主机的 #filePath，将正式 fixture 复制进各测试 bundle。
        .testTarget(name: "VAPPlayerKitTests", dependencies: ["VAPPlayerKit"],
                    path: "Tests", exclude: ["HostedTestBundle.swift", "Fixtures/README.md", "VAPPlayerKitParserTests", "VAPPlayerKitTimingTests", "VAPPlayerKitRendererTests"],
                    sources: ["VAPPlayerKitTests"], resources: [.copy("Fixtures/VAP")]),
        .testTarget(name: "VAPPlayerKitTimingTests", dependencies: ["VAPPlayerKit"]),
        // 真机无法读取构建主机的 #filePath，将正式 fixture 复制进各测试 bundle。
        .testTarget(name: "VAPPlayerKitParserTests", dependencies: ["VAPPlayerKit"],
                    path: "Tests", exclude: ["HostedTestBundle.swift", "Fixtures/README.md", "VAPPlayerKitTests", "VAPPlayerKitTimingTests", "VAPPlayerKitRendererTests"],
                    sources: ["VAPPlayerKitParserTests"], resources: [.copy("Fixtures/VAP")]),
        .testTarget(name: "VAPPlayerKitRendererTests", dependencies: ["VAPPlayerKit"])
    ],
    swiftLanguageModes: [.v6]
)
