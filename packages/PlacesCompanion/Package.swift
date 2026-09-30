// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlacesCompanion",
    platforms: [.iOS("26.0"), .macOS(.v15), .watchOS("11.0")],
    products: [.library(name: "PlacesCompanion", targets: ["PlacesCompanion"])],
    targets: [.target(name: "PlacesCompanion"),
              .testTarget(name: "PlacesCompanionTests", dependencies: ["PlacesCompanion"])]
)
