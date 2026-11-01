// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        // 默认 product type 为 .staticFramework，直接使用默认值
    )
#endif

let package = Package(
    name: "iJog",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
    ]
)
