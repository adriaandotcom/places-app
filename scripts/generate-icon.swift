#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Export the Icon Composer source so fallback icons cannot drift to an older logo.
// Run from the repository root with Xcode selected.
func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PlacesIconExport", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(executable.lastPathComponent) failed: \(String(decoding: data, as: UTF8.self))"])
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
let developer = try run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"])
let renderer = URL(fileURLWithPath: developer).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
let source = URL(fileURLWithPath: "apps/ios/Places/Resources/AppIcon.icon").path
let folder = URL(fileURLWithPath: "apps/ios/Places/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PlacesIcon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (rendition, filename, background) in [("Default", "AppIcon.png", CGFloat(0.75)),
                                           ("Dark", "AppIcon-dark.png", CGFloat(0.08))] {
    let exported = temporary.appendingPathComponent(filename)
    _ = try run(renderer, [source, "--export-image", "--output-file", exported.path,
                           "--platform", "iOS", "--rendition", rendition,
                           "--width", "1024", "--height", "1024", "--scale", "1"])
    guard let imageSource = CGImageSourceCreateWithURL(exported as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw NSError(domain: "PlacesIconExport", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Could not read or flatten \(rendition) export."])
    }
    // Asset-catalog fallbacks must be opaque; iOS masks these corners itself.
    let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.setFillColor(CGColor(gray: background, alpha: 1))
    context.fill(bounds)
    context.draw(image, in: bounds)
    guard let flattened = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(filename) as CFURL,
              UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "PlacesIconExport", code: 3)
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PlacesIconExport", code: 4)
    }
}
try """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"AppIcon-dark.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}

""".write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
