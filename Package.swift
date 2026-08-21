// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VAPPlayerKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "VAPPlayerKit",
            targets: [
                "VAPPlayerKit",
                "VAPPlayerKitObjC"
            ]
        )
    ],
    targets: [
        .target(
            name: "VAPPlayerKit",
            dependencies: [],
            path: "Sources/VAPPlayerKit",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "VAPPlayerKitObjC",
            dependencies: [],
            path: "Sources/VAPPlayerKitObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("UIKit")
            ]
        ),
        .testTarget(
            name: "VAPPlayerKitTests",
            dependencies: ["VAPPlayerKit"],
            path: "Tests/VAPPlayerKitTests"
        ),
        .testTarget(
            name: "VAPPlayerKitTimingTests",
            dependencies: ["VAPPlayerKit"],
            path: "Tests/VAPPlayerKitTimingTests"
        ),
        .testTarget(
            name: "VAPPlayerKitParserTests",
            dependencies: ["VAPPlayerKit"],
            path: "Tests/VAPPlayerKitParserTests"
        ),
        .testTarget(
            name: "VAPPlayerKitRendererTests",
            dependencies: ["VAPPlayerKit"],
            path: "Tests/VAPPlayerKitRendererTests"
        ),
        .testTarget(
            name: "VAPPlayerKitObjCTests",
            dependencies: [
                "VAPPlayerKit",
                "VAPPlayerKitObjC"
            ],
            path: "Tests/VAPPlayerKitObjCTests"
        )
    ]
)
