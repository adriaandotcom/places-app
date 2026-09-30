import SwiftUI

/// The marker from AppIcon.icon, rendered as a template instead of a coloured bitmap.
struct PlacesMarker: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 416, rect.height / 564)
        let transform = CGAffineTransform(translationX: -358, y: -144)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (rect.width - 416 * scale) / 2,
                                            y: (rect.height - 564 * scale) / 2))
        var path = Path()
        path.move(to: CGPoint(x: 566, y: 144))
        path.addCurve(to: CGPoint(x: 358, y: 350), control1: CGPoint(x: 450, y: 144), control2: CGPoint(x: 358, y: 235))
        path.addCurve(to: CGPoint(x: 566, y: 708), control1: CGPoint(x: 358, y: 475), control2: CGPoint(x: 566, y: 708))
        path.addCurve(to: CGPoint(x: 774, y: 350), control1: CGPoint(x: 566, y: 708), control2: CGPoint(x: 774, y: 475))
        path.addCurve(to: CGPoint(x: 566, y: 144), control1: CGPoint(x: 774, y: 235), control2: CGPoint(x: 682, y: 144))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: 490, y: 274, width: 152, height: 152))
        return path.applying(transform)
    }
}
