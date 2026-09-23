import SwiftUI
import PlacesCore

struct WiFiClassificationPicker: View {
    @Environment(AppModel.self) private var model
    let network: WiFiNetwork
    @State private var expanded = false
    private var classification: WiFiClassification {
        model.networks.first { $0.id == network.id }?.classification ?? network.classification
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Layout.compact) {
                    Image(systemName: "wifi")
                    Text(network.ssid).font(BrandFont.title).multilineTextAlignment(.leading)
                    Spacer(minLength: Layout.compact)
                    Label(classification.title, systemImage: classification.symbol)
                        .font(.subheadline).foregroundStyle(Palette.green)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Palette.muted)
                }.frame(minHeight: Layout.touchTarget).foregroundStyle(Palette.ink)
            }.buttonStyle(.plain).accessibilityHint("Change network type")
            if expanded {
                ForEach([WiFiClassification.fixed, .shared, .portable, .ignored], id: \.self) { option in
                    Button { Task { await model.classify(network, as: option); expanded = false } } label: {
                        HStack(spacing: Layout.spacing) {
                            Image(systemName: option.symbol).font(.title3).frame(width: Layout.touchTarget)
                            VStack(alignment: .leading, spacing: Layout.compact) {
                                Text(option.title + (option == .fixed ? " · Default" : "")).font(BrandFont.title)
                                Text(option.detail).font(.subheadline).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                            if classification == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                        }.padding(Layout.compact).frame(minHeight: Layout.touchTarget).foregroundStyle(Palette.ink)
                            .background(classification == option ? Palette.soft(0) : Palette.paper, in: RoundedRectangle(cornerRadius: Layout.spacing))
                    }.buttonStyle(.plain).accessibilityAddTraits(classification == option ? .isSelected : [])
                }
            }
        }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
    }
}

private extension WiFiClassification {
    var title: String {
        switch self { case .fixed: "Fixed"; case .shared: "Shared"; case .portable: "Portable"; case .ignored: "Ignored"; case .unclassified: "Choose type" }
    }
    var symbol: String {
        switch self { case .fixed: "house.fill"; case .shared: "building.2.fill"; case .portable: "personalhotspot"; case .ignored: "eye.slash"; case .unclassified: "questionmark.circle" }
    }
    var detail: String {
        switch self {
        case .fixed, .unclassified: "Stays in one place, like home or work."
        case .shared: "The same name is used at several places."
        case .portable: "Travels with you, like a hotspot."
        case .ignored: "Never use this network to recognize a place."
        }
    }
}
