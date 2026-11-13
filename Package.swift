// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Purerify",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Purerify",
            targets: ["Purerify"]
        ),
    ],
    targets: [
        .target(name: "Purerify"),
    ]
)
