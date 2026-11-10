// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ferrostar_flutter",
    // FerrostarCore requires iOS 16.
    platforms: [.iOS("16.0")],
    products: [
        .library(name: "ferrostar-flutter", targets: ["ferrostar_flutter"]),
    ],
    dependencies: [
        // Pre-1.0 core: pinned to an exact release on purpose (API churn).
        .package(url: "https://github.com/stadiamaps/ferrostar", exact: "0.59.0"),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "ferrostar_flutter",
            dependencies: [
                .product(name: "FerrostarCore", package: "ferrostar"),
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ]
        ),
    ]
)
