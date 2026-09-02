// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FolderApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Folder",
            targets: ["FolderApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "FolderApp",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/FolderApp",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(
            name: "FolderAppTests",
            dependencies: [
                "FolderApp",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/FolderAppTests"
        )
    ]
)
