import SwiftUI
import PlacesCore

enum Palette {
    static let background = adaptive(light: 0xFAF7EF, dark: 0x191A17)
    static let ink = adaptive(light: 0x30281E, dark: 0xF5F1E7)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x262823)
    static let line = adaptive(light: 0xE7E1D5, dark: 0x41443B)
    static let muted = adaptive(light: 0x716A5E, dark: 0xB9B5AA)
    static let warning = adaptive(light: 0x805400, dark: 0xF5C56B)
    static let green = adaptive(light: 0x287D45, dark: 0x6BC58A)
    static let controlGreen = Color(red: 40 / 255, green: 125 / 255, blue: 69 / 255)
    static let accents: [Color] = [controlGreen, Color(red: 0.23, green: 0.50, blue: 0.85),
        Color(red: 0.82, green: 0.48, blue: 0.17), Color(red: 0.79, green: 0.36, blue: 0.24),
        Color(red: 0.58, green: 0.39, blue: 0.76), Color(red: 0.15, green: 0.54, blue: 0.58)]
    static func accent(_ index: Int) -> Color { accents[abs(index % accents.count)] }
    static func soft(_ index: Int) -> Color {
        let light: [UInt] = [0xDCEFD9, 0xD9E9FC, 0xFBE9C2, 0xF8DECD, 0xEBDDFA, 0xD6EEEC]
        let dark: [UInt] = [0x233D2B, 0x233548, 0x443722, 0x473023, 0x392B47, 0x203C3D]
        let i = abs(index % light.count)
        return adaptive(light: light[i], dark: dark[i])
    }
    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}
enum BrandFont {
    static let hero = Font.custom("BricolageGrotesque-ExtraBold", size: 34, relativeTo: .largeTitle)
    static let heading = Font.custom("BricolageGrotesque-Bold", size: 23, relativeTo: .title2)
    static let title = Font.custom("BricolageGrotesque-Bold", size: 18, relativeTo: .headline)
    static let body = Font.custom("BricolageGrotesque-Regular", size: 16, relativeTo: .body)
}
enum Layout {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 24
    static let spacing: CGFloat = 16
    static let compact: CGFloat = 8
    static let touchTarget: CGFloat = 44
    static let iconTile: CGFloat = 76
    static let mapHeight: CGFloat = 280
}

struct PlaceIcon: View {
    var symbol: String
    var colorIndex: Int = 0
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(Palette.accent(colorIndex), in: RoundedRectangle(cornerRadius: size * 0.3))
            .rotationEffect(.degrees(-4)).accessibilityHidden(true)
    }
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(BrandFont.title).frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(Palette.background).background(Palette.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
struct EmptyHistory: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(Palette.green)
                .frame(width: 88, height: 88).background(Palette.soft(0), in: RoundedRectangle(cornerRadius: 28))
            Text(title).font(BrandFont.heading)
            Text(message).font(BrandFont.body).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 40)
    }
}
struct InfoRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var colorIndex = 0
    var body: some View {
        HStack(spacing: 14) {
            PlaceIcon(symbol: symbol, colorIndex: colorIndex, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BrandFont.title)
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: 20))
    }
}
enum Display {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }
    static func range(_ item: TimelineItem) -> String {
        let start = item.start.formatted(date: .omitted, time: .shortened)
        return start + " – " + (item.end?.formatted(date: .omitted, time: .shortened) ?? "now")
    }
}

struct InlineNotice: View {
    var title: String
    var message: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: Layout.compact) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? Color.red : Palette.warning)
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(title).font(BrandFont.title)
                Text(message).font(.subheadline).foregroundStyle(Palette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.spacing).background(Palette.soft(2), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
            .accessibilityElement(children: .combine)
    }
}
