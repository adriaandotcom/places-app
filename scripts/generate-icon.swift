#!/usr/bin/env swift
import AppKit
import Foundation

// A vector drawing, kept reproducible in source. Run from the repository root.
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(red: 0.20, green: 0.56, blue: 0.31, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 116, y: 116, width: 792, height: 792), xRadius: 245, yRadius: 245).fill()
NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
let pin = NSBezierPath()
pin.move(to: NSPoint(x: 512, y: 254))
pin.curve(to: NSPoint(x: 312, y: 584), controlPoint1: NSPoint(x: 390, y: 360), controlPoint2: NSPoint(x: 312, y: 468))
pin.curve(to: NSPoint(x: 712, y: 584), controlPoint1: NSPoint(x: 312, y: 850), controlPoint2: NSPoint(x: 712, y: 850))
pin.curve(to: NSPoint(x: 512, y: 254), controlPoint1: NSPoint(x: 712, y: 468), controlPoint2: NSPoint(x: 634, y: 360))
pin.close(); pin.fill()
NSColor(red: 0.20, green: 0.56, blue: 0.31, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 432, y: 526, width: 160, height: 160)).fill()
NSGraphicsContext.restoreGraphicsState()
let folder = URL(fileURLWithPath: "apps/ios/Places/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("AppIcon.png"))
try """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}

""".write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
