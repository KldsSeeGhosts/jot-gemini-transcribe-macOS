// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Jot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Clipy/Sauce.git", from: "2.2.0"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionGuard",
            path: "JotCore/ObjCExceptionGuard"
        ),
        .target(
            name: "JotCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Sauce",
                "ObjCExceptionGuard",
            ],
            path: "JotCore/Sources"
        ),
        .executableTarget(
            name: "Jot",
            dependencies: ["JotCore"],
            path: "App/Sources"
        ),
    ]
)
