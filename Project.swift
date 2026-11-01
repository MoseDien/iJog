import ProjectDescription

let project = Project(
    name: "iJog",
    settings: .settings(
        base: [
            // 设备调试签名（Xcode GUI 打开 workspace 即可直接 Run，无需手选 Team）
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "4V4QEMAAYL",
        ]
    ),
    targets: [
        .target(
            name: "iJog",
            destinations: .iOS,
            product: .app,
            bundleId: "com.belldien.iJog",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "NSLocationWhenInUseUsageDescription": "iJog 需要访问你的位置来记录跑步轨迹。",
                "UIBackgroundModes": ["location"],
                "NSUbiquitousContainers": [
                    "iCloud.com.belldien.iJog": [
                        "NSUbiquitousContainerIsDocumentScopePublic": true,
                        "NSUbiquitousContainerName": "iJog",
                        "NSUbiquitousContainerSupportedFolderLevels": "Any",
                    ]
                ],
            ]),
            sources: ["iJog/Sources/**"],
            resources: ["iJog/Resources/**"],
            entitlements: .dictionary([
                "com.apple.developer.icloud-container-identifiers": ["iCloud.com.belldien.iJog"],
                "com.apple.developer.icloud-services": ["CloudDocuments"],
            ]),
            dependencies: [
                .external(name: "ComposableArchitecture"),
            ]
        ),
        .target(
            name: "iJogTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.belldien.iJogTests",
            infoPlist: .default,
            sources: ["iJog/Tests/**"],
            resources: [],
            dependencies: [
                .target(name: "iJog"),
            ]
        ),
    ]
)
