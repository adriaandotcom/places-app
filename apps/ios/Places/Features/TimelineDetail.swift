import SwiftUI
import PlacesCore

struct TimelineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    @State private var placeFlow: PlaceFlow?
    @State private var createdPlace = false
    private enum PlaceFlow: String, Identifiable {
        case create, choose
        var id: String { rawValue }
    }
    private var place: Place? { model.place(for: item) }
    private var isUnnamedStay: Bool { item.kind == .stay && place == nil }
    private var title: String {
        switch item.kind {
        case .stay: place?.name ?? "Somewhere new"
        case .journey: item.mode.title
        case .gap: "An unknown interval"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PlaceIcon(symbol: item.kind == .gap ? "questionmark" : item.kind == .journey ? item.mode.symbol : place?.symbol ?? "mappin",
                          colorIndex: place?.colorIndex ?? 4, size: 64)
                Text(title).font(BrandFont.hero)
                Text(item.start.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(Palette.muted)
                HStack {
                    Text(Display.range(item)).font(BrandFont.title)
                    Spacer()
                    Text(Display.duration(item.duration())).font(.subheadline).foregroundStyle(Palette.muted)
                }
                if item.kind == .gap {
                    Text("There aren’t enough observations to say where you were. You can fill this interval yourself, or leave it unknown.").font(BrandFont.body)
                } else if model.mapsEnabled {
                    PrivacyMapView(items: [item]).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 24))
                }
                if let place {
                    NavigationLink { PlaceDetail(placeID: place.id) } label: { InfoRow(symbol: place.symbol, title: "About this place", subtitle: place.name, colorIndex: place.colorIndex) }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.isUserEdited ? "Your correction" : "Why this appears here").font(BrandFont.heading)
                    ForEach(item.reasons, id: \.self) { Text($0).font(BrandFont.body).foregroundStyle(Palette.muted) }
                }
                if model.nerdMode {
                    InfoRow(symbol: "waveform.path", title: "Evidence", subtitle: "\(item.evidenceIDs.count) source observations · policy \(TrackingPolicy.version)", colorIndex: 5)
                    Text("Last evidence: \(item.lastEvidenceAt.formatted())").font(.caption.monospaced()).foregroundStyle(Palette.muted)
                }
                VStack(spacing: 12) {
                    Button(isUnnamedStay ? "Name this place" : item.kind == .gap ? "I was at a place" : "Change assigned place") {
                        placeFlow = isUnnamedStay || model.places.isEmpty ? .create : .choose
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("assign-place")
                    if isUnnamedStay && !model.places.isEmpty {
                        Button("Choose a saved place") { placeFlow = .choose }.frame(minHeight: 44)
                            .accessibilityIdentifier("choose-saved-place")
                    }
                    Menu(item.kind == .gap ? "I was travelling" : "Change transport mode") {
                        ForEach(TransportMode.allCases, id: \.self) { mode in
                            Button(mode.title, systemImage: mode.symbol) { correct(kind: .journey, mode: mode) }
                        }
                    }.frame(minHeight: 44)
                    if item.kind != .gap { Button("Mark as unknown") { correct(kind: .gap) }.frame(minHeight: 44) }
                    if item.end == nil {
                        Text("Corrections to an ongoing interval apply through now. Future observations remain separate.").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $placeFlow, onDismiss: { if createdPlace { dismiss() } }) { flow in
                NavigationStack {
                    if flow == .create {
                        newPlaceEditor
                    } else {
                        List {
                            NavigationLink { newPlaceEditor } label: {
                                Label("Create a new place", systemImage: "plus.circle.fill").frame(minHeight: 44)
                            }.accessibilityIdentifier("create-assigned-place")
                            ForEach(model.places) { place in
                                Button { placeFlow = nil; correct(kind: .stay, placeID: place.id) } label: {
                                    Label(place.name, systemImage: place.symbol).frame(minHeight: 44)
                                }
                            }
                        }.navigationTitle("Choose a place")
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { placeFlow = nil } } }
                    }
                }
            }
    }
    private var newPlaceEditor: some View {
        PlaceEditor(coordinate: item.coordinate, assigning: item) {
            createdPlace = true
            placeFlow = nil
        }
    }
    private func correct(kind: TimelineKind, placeID: String? = nil, mode: TransportMode = .unknown) {
        Task { if await model.correct(item, kind: kind, placeID: placeID, mode: mode) { dismiss() } }
    }
}
