// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlacesCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "PlacesCore", targets: ["PlacesCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "PlacesCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "ZIPFoundation"], resources: [.copy("Resources/PlaceCatalog")]),
        .testTarget(name: "PlacesCoreTests", dependencies: ["PlacesCore"])
    ]
)
