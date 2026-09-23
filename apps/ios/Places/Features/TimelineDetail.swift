import SwiftUI
import PlacesCore

struct TimelineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    @State private var choosingPlace = false
    @State private var addingPlace = false
    private var place: Place? { model.place(for: item) }
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
                    Button(item.kind == .gap ? "I was at a place" : "Change assigned place") { choosingPlace = true }.buttonStyle(PrimaryButton())
                    if item.kind == .stay && place == nil && item.coordinate != nil {
                        Button("Name this place") { addingPlace = true }.frame(minHeight: 44)
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
            .sheet(isPresented: $choosingPlace) {
                NavigationStack {
                    List {
                        if model.places.isEmpty { Text("Add a place in the Places tab first, then assign it here.") }
                        ForEach(model.places) { place in
                            Button { choosingPlace = false; correct(kind: .stay, placeID: place.id) } label: {
                                Label(place.name, systemImage: place.symbol).frame(minHeight: 44)
                            }
                        }
                    }.navigationTitle("Choose a place")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingPlace = false } } }
                }
            }
            .sheet(isPresented: $addingPlace) { NavigationStack { PlaceEditor(coordinate: item.coordinate) } }
    }
    private func correct(kind: TimelineKind, placeID: String? = nil, mode: TransportMode = .unknown) {
        Task { if await model.correct(item, kind: kind, placeID: placeID, mode: mode) { dismiss() } }
    }
}
