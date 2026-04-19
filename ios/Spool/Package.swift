// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Spool", targets: ["Spool"]),
        .executable(name: "SpoolMac", targets: ["SpoolMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Spool",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "Sources/Spool"
        ),
        .executableTarget(
            name: "SpoolMac",
            dependencies: ["Spool"],
            path: "Sources/SpoolMac"
        ),
        .testTarget(
            name: "SpoolTests",
            dependencies: ["Spool"],
            path: "Tests/SpoolTests"
        ),
    ]
)
