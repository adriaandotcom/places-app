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
    static let navigation = Color(red: 0.16, green: 0.14, blue: 0.11)
    static let navigationInk = Color.white.opacity(0.85)
    static let navigationSelected = Color(red: 0.98, green: 0.96, blue: 0.92)
    static let navigationSelectedInk = Color(red: 0.19, green: 0.16, blue: 0.12)
    static let accents: [Color] = [controlGreen, Color(red: 0.23, green: 0.50, blue: 0.85),
        Color(red: 0.82, green: 0.48, blue: 0.17), Color(red: 0.79, green: 0.36, blue: 0.24),
        Color(red: 0.58, green: 0.39, blue: 0.76), Color(red: 0.15, green: 0.54, blue: 0.58)]
    static func accent(_ index: Int, hex: String? = nil) -> Color {
        guard let hex, hex.count == 6, let rgb = UInt(hex, radix: 16) else { return accents[abs(index % accents.count)] }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    static func iconInk(_ index: Int, hex: String? = nil) -> Color {
        guard let hex, hex.count == 6, let rgb = UInt(hex, radix: 16) else { return .white }
        func linear(_ value: UInt) -> Double { let v = Double(value) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let light = 0.2126 * linear((rgb >> 16) & 255) + 0.7152 * linear((rgb >> 8) & 255) + 0.0722 * linear(rgb & 255)
        return light > 0.179 ? .black : .white
    }
    static func hex(_ color: Color) -> String {
        // The system picker also supports Display P3. Persist predictable sRGB
        // bytes, clamping colors outside that gamut instead of overflowing hex.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = UIColor(color).cgColor.converted(to: space, intent: .defaultIntent, options: nil)
        let components = converted?.components ?? [0, 0, 0, 1]
        return components.prefix(3).map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }
    static func soft(_ index: Int, hex: String? = nil) -> Color {
        if let hex, hex.count == 6, let rgb = UInt(hex, radix: 16) {
            func blend(_ base: UInt, _ fraction: Double) -> UInt {
                [16, 8, 0].reduce(UInt(0)) { value, shift in
                    value | UInt((Double((rgb >> shift) & 255) * fraction + Double(base) * (1 - fraction)).rounded()) << shift
                }
            }
            return adaptive(light: blend(255, 0.18), dark: blend(25, 0.25))
        }
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
    static let rewindNumber = Font.custom("BricolageGrotesque-ExtraBold", size: 88, relativeTo: .largeTitle)
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
    static let timelineInset: CGFloat = 55
    static let timelineSpineInset: CGFloat = 38
    static let timelineRowHeight: CGFloat = 78
    static let timelineRowHorizontal: CGFloat = 12
    static let timelineRowVertical: CGFloat = 10
    static let iconTile: CGFloat = 76
    static let mapHeight: CGFloat = 280
    static let islandInset: CGFloat = 6
    static let navigationItemHeight: CGFloat = 48
    static let navigationIslandHeight: CGFloat = 72
    static let avatarSize: CGFloat = 52
    static let avatarOverlap: CGFloat = 8
    static let avatarBorder: CGFloat = 3
    static let portraitSize: CGFloat = 96
    static let readingLineSpacing: CGFloat = 8
    static let noteEditorHeight: CGFloat = 150
}

struct FloatingIsland: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(Layout.islandInset).foregroundStyle(Palette.navigationInk)
            .background(Palette.navigation, in: Capsule())
    }
}

struct MemoryReadingStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var spacing = Layout.readingLineSpacing
    func body(content: Content) -> some View { content.font(BrandFont.body).lineSpacing(spacing) }
}

struct PlaceIcon: View {
    var symbol: String
    var colorIndex: Int = 0
    var customColorHex: String?
    var photoJPEG: Data?
    var size: CGFloat = 44
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Palette.accent(colorIndex, hex: customColorHex)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(Palette.iconInk(colorIndex, hex: customColorHex))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.3))
            .rotationEffect(.degrees(-4)).accessibilityHidden(true)
            .onChange(of: photoJPEG, initial: true) { _, data in image = data.flatMap { UIImage(data: $0) } }
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
struct InfoRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var colorIndex = 0
    var customColorHex: String?
    var photoJPEG: Data?
    var card = true
    var showsDisclosure = false
    var body: some View {
        Group {
            if card { content.modifier(CardSurface()) }
            else { content }
        }
    }
    private var content: some View {
        HStack(spacing: Layout.spacing) {
            PlaceIcon(symbol: symbol, colorIndex: colorIndex, customColorHex: customColorHex, photoJPEG: photoJPEG, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BrandFont.title)
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
            if showsDisclosure { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).accessibilityHidden(true) }
        }.frame(minHeight: Layout.touchTarget)
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
            .modifier(CardSurface(color: Palette.soft(2)))
            .accessibilityElement(children: .combine)
    }
}

/// Reserve scrollable space for the floating main controls, including pushed pages.
extension EnvironmentValues {
    @Entry var hasMainNavigation = false
}

struct MainNavigationClearance: ViewModifier {
    @Environment(\.hasMainNavigation) private var hasMainNavigation
    func body(content: Content) -> some View {
        content.contentMargins(.bottom, hasMainNavigation ? Layout.navigationIslandHeight + Layout.spacing : 0, for: .scrollContent)
    }
}
