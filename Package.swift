// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unlockface",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "UnlockKit",
            path: "Sources/UnlockKit",
            // Unlockface와 동일한 이유(ScreenLockMonitor 등 델리게이트/타이머 콜백)로 v5 유지
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Unlockface",
            dependencies: ["UnlockKit"],
            path: "Sources/Unlockface",
            // Phase 1은 AVFoundation 델리게이트 콜백이 많아 v6 엄격 동시성 대신 v5 모드 사용
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Unlockpalm",
            dependencies: ["UnlockKit"],
            path: "Sources/Unlockpalm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UnlockKitTests",
            dependencies: ["UnlockKit"],
            path: "Tests/UnlockKitTests"
        )
    ]
)
