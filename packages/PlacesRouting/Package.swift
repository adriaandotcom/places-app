// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlacesRouting",
    platforms: [.iOS("26.0")],
    products: [.library(name: "PlacesRouting", targets: ["PlacesRouting"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .binaryTarget(name: "ValhallaWrapper",
            url: "https://github.com/Rallista/valhalla-mobile/releases/download/0.6.4/valhalla-wrapper.xcframework.zip",
            checksum: "c12b796de073e89f6b0be02cbfabf845a324166467609268d747c094d27ddb47"),
        .target(name: "PlacesRoutingNative", dependencies: ["ValhallaWrapper"],
                linkerSettings: [.linkedLibrary("z")]),
        .target(name: "PlacesRouting", dependencies: ["PlacesRoutingNative", "ZIPFoundation"],
                resources: [.copy("Resources/config.json"), .copy("Resources/tzdata"), .copy("Resources/packs.json")])
    ],
    cxxLanguageStandard: .cxx20
)
