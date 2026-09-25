import SwiftUI
import PlacesCore

struct TimelineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: TimelineItem
    @State private var namingDraft: NamingDraft?
    private struct NamingDraft: Identifiable {
        let id = UUID()
        let suggestion: CatalogPlace?
    }
    @State private var suggestions: [CatalogPlace] = []
    @State private var splitting = false
    @State private var didSplit = false
    @State private var createdPlace = false
    @State private var transportSuggestions = TransportSuggestions.none
    private var place: Place? { model.place(for: item) }
    private var isUnnamedStay: Bool { item.kind == .stay && place == nil }
    private var title: String {
        switch item.kind {
        case .stay: place?.name ?? "Somewhere new"
        case .journey: item.mode.title
        case .gap: item.connection == nil ? "An unknown interval" : "Between recorded locations"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                HStack(spacing: Layout.spacing) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        PlaceIcon(symbol: item.kind == .gap ? "questionmark" : item.kind == .journey ? item.mode.symbol : place?.symbol ?? "mappin",
                                  colorIndex: place?.colorIndex ?? 4)
                    }
                    Text(title).font(BrandFont.heading)
                }
                timeLayout {
                    Text("\(Text(Display.range(item)).font(BrandFont.title)) · \(Text(item.start.formatted(date: .abbreviated, time: .omitted)).font(.subheadline))")
                        .accessibilityIdentifier("visit-time-date")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Layout.compact) }
                    Text(Display.duration(item.duration())).font(.subheadline).foregroundStyle(Palette.muted)
                }
                if isUnnamedStay || item.kind == .gap {
                    Button(isUnnamedStay ? "Name this place" : item.kind == .gap ? "I was at a place" : "Change place") {
                        namingDraft = NamingDraft(suggestion: nil)
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("assign-place")
                }
                if isUnnamedStay && !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { candidate in
                            Button {
                                namingDraft = NamingDraft(suggestion: candidate)
                            } label: {
                                HStack {
                                    CatalogPlaceRow(place: candidate, anchor: item.coordinate,
                                        saved: candidate.reference.savedPlace(in: model.places) != nil, compact: true)
                                    Spacer(minLength: Layout.compact)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                                }.padding(.horizontal, Layout.spacing).padding(.vertical, Layout.compact)
                            }.buttonStyle(.plain).accessibilityIdentifier("visit-suggestion-\(candidate.id)")
                            if candidate.id != suggestions.last?.id { Divider().padding(.horizontal, Layout.spacing) }
                        }
                    }.background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                }
                if item.kind == .gap {
                    Text(item.connection == nil
                         ? "There aren’t enough observations to say where you were. You can fill this interval yourself, or leave it unknown."
                         : "We know these two locations. The path and any stops between them weren’t recorded.").font(BrandFont.body)
                }
                if let connection = item.connection {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.endpointName(connection.from, fallback: "Earlier location"), systemImage: "a.circle.fill")
                        Label(model.endpointName(connection.to, fallback: "Later location"), systemImage: "b.circle.fill")
                    }.font(BrandFont.body)
                }
                if model.mapsEnabled && (item.kind != .gap || item.connection != nil) {
                    PrivacyMapView(items: [item]).frame(height: Layout.mapHeight).clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                    if item.connection != nil {
                        Text("Dashed lines link known endpoints; they aren’t a recorded route.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if let place {
                    NavigationLink { PlaceDetail(placeID: place.id) } label: { InfoRow(symbol: place.symbol, title: "About this place", subtitle: place.name, colorIndex: place.colorIndex) }.buttonStyle(.plain)
                }
                if item.isUserEdited { Text("Your correction").font(.caption).foregroundStyle(Palette.muted) }
                NavigationLink { VisitEvidenceView(item: item) } label: {
                    HStack {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: Layout.compact) {
                                Text("Evidence")
                                Text("\(Set(item.evidenceIDs).count) observations").foregroundStyle(Palette.muted)
                            }
                        } else {
                            Label("Evidence", systemImage: "waveform.path")
                        }
                        Spacer()
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("\(Set(item.evidenceIDs).count) observations").foregroundStyle(Palette.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }.font(.subheadline).frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("visit-evidence")
                if let originals = item.originalItems, originals.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(originals.count) entries combined").font(BrandFont.title)
                            .accessibilityIdentifier("combined-entries")
                        if item.unrecordedDuration > 0 {
                            Text("Includes \(item.unrecordedDuration < 60 ? "less than a minute" : Display.duration(item.unrecordedDuration)) without locations. The same place was recorded on both sides.")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .task(id: item) {
                transportSuggestions = (try? await model.store?.transportSuggestions(for: item)) ?? .none
                if isUnnamedStay, let point = item.coordinate {
                    suggestions = (try? await PlaceCatalog.shared.nearby(point, limit: 3)) ?? []
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(item.kind == .stay ? "Change place" : "I was at a place", systemImage: "mappin") { namingDraft = NamingDraft(suggestion: nil) }
                        transportMenu
                        if (item.originalItems?.count ?? 0) > 1 {
                            Button("Split into original entries…", systemImage: "arrow.triangle.branch") { splitting = true }
                                .accessibilityIdentifier("split-entries")
                        }
                        if item.isSeparated == true {
                            Button("Merge with adjacent entries", systemImage: "arrow.triangle.merge") {
                                Task { if await model.setCombined(item, combined: true) { dismiss() } }
                            }.accessibilityIdentifier("merge-entries")
                        }
                        if item.kind == .journey || place != nil {
                            Button("Mark as unknown", systemImage: "questionmark.circle") { correct(kind: .gap) }
                        }
                    } label: { Image(systemName: "pencil").frame(minWidth: 28, minHeight: 28) }
                        .accessibilityLabel("Edit entry").accessibilityIdentifier("edit-entry")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $splitting, onDismiss: { if didSplit { dismiss() } }) {
                NavigationStack { SplitEntriesView(item: item) { didSplit = true; splitting = false } }
            }
            .sheet(item: $namingDraft, onDismiss: { if createdPlace { dismiss() } }) { draft in
                NavigationStack {
                    PlaceEditor(coordinate: item.coordinate, assigning: item, suggestion: draft.suggestion) {
                        createdPlace = true; namingDraft = nil
                    }
                }
            }
    }
    private var timeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Layout.compact))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }
    private var transportMenu: some View {
        Menu(item.kind == .journey ? "Change transport mode" : "I was travelling") {
            if let speed = transportSuggestions.estimatedSpeedKilometersPerHour {
                Section("Suggested · about \(Int(speed.rounded())) km/h") { transportButtons(transportSuggestions.suggested) }
                Section("Other ways") { transportButtons(transportSuggestions.otherModes) }
            } else { transportButtons(TransportMode.choiceOrder) }
        }.menuOrder(.fixed).frame(minHeight: Layout.touchTarget).accessibilityIdentifier("change-transport")
    }
    private func transportButtons(_ modes: [TransportMode]) -> some View {
        ForEach(modes, id: \.self) { mode in
            Button(mode.choiceTitle, systemImage: mode.symbol) { correct(kind: .journey, mode: mode) }
                .accessibilityIdentifier("transport-\(mode.rawValue)")
        }
    }
    private func correct(kind: TimelineKind, placeID: String? = nil, mode: TransportMode = .unknown) {
        Task { if await model.correct(item, kind: kind, placeID: placeID, mode: mode) { dismiss() } }
    }
}

private struct VisitEvidenceView: View {
    @Environment(AppModel.self) private var model
    let item: TimelineItem
    @State private var observations: [SensorObservation] = []
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        List {
            Section(item.isUserEdited ? "Your correction" : "Why this appears here") {
                ForEach(item.reasons, id: \.self) { Text($0) }
            }
            Section("Recorded observations") {
                if loading { ProgressView("Loading evidence…") }
                else if failed {
                    Text("Evidence couldn’t be loaded.")
                    Button("Try again") { attempt += 1 }
                } else if observations.isEmpty {
                    Text(item.isUserEdited ? "This entry comes from your correction. No source observations are attached."
                         : "No source observations are attached to this interval.")
                } else {
                    ForEach(EvidenceGroup.make(observations)) { group in
                        let observation = group.first
                        DisclosureGroup {
                            ForEach(group.observations) { observation in
                                if group.observations.count > 1 { Text(timestamp(observation)).font(.caption.bold()) }
                            if let point = observation.coordinate {
                                LabeledContent("Latitude", value: String(format: "%.5f", point.latitude))
                                LabeledContent("Longitude", value: String(format: "%.5f", point.longitude))
                            }
                            if let accuracy = observation.horizontalAccuracy, accuracy >= 0 {
                                LabeledContent("Location accuracy", value: "±\(Int(accuracy.rounded())) m")
                            }
                            if let measured = observation.coordinateTimestamp, measured != observation.timestamp {
                                LabeledContent("Location measured", value: measured.formatted())
                            }
                            if let speed = observation.speed, speed >= 0 {
                                LabeledContent("Speed", value: String(format: "%.1f km/h", speed * 3.6))
                            }
                            if let motion = observation.motion { LabeledContent("Motion", value: motion.rawValue.capitalized) }
                            if let ssid = observation.ssid { LabeledContent("Connected Wi-Fi", value: ssid) }
                            LabeledContent("Time zone", value: observation.timezoneIdentifier)
                            if model.nerdMode { LabeledContent("Recording policy", value: observation.policyVersion) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: Layout.compact) {
                                Text(observation.source == .wifi && observation.ssid == nil ? "Wi-Fi unavailable" : sourceName(observation.source)).font(BrandFont.title)
                                Text(timestamp(observation)).font(.subheadline).foregroundStyle(Palette.muted)
                                if group.observations.count > 1 {
                                    Text("\(group.observations.count) checks · through \(group.observations.last!.timestamp.formatted(date: .omitted, time: .standard))")
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                            }.padding(.vertical, Layout.compact)
                        }.accessibilityIdentifier("evidence-observation-\(observation.id)")
                    }
                    if observations.count < Set(item.evidenceIDs).count {
                        Text("Some referenced observations are no longer available.").foregroundStyle(Palette.muted)
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Evidence").navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                loading = true; failed = false
                do {
                    guard let store = model.store else { failed = true; loading = false; return }
                    observations = try await store.evidence(for: item)
                } catch { failed = true }
                loading = false
            }
    }
    private func timestamp(_ observation: SensorObservation) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        style.timeZone = TimeZone(identifier: observation.timezoneIdentifier) ?? .current
        return observation.timestamp.formatted(style)
    }
    private func sourceName(_ source: ObservationSource) -> String {
        switch source {
        case .location: "Location reading"
        case .significantChange: "Significant location change"
        case .visitArrival: "Visit arrival"
        case .visitDeparture: "Visit departure"
        case .regionEnter: "Entered a saved place"
        case .regionExit: "Left a saved place"
        case .motion: "Motion reading"
        case .wifi: "Wi-Fi connection check"
        case .recovery: "Recording recovery"
        case .paused: "Recording paused"
        case .resumed: "Recording resumed"
        }
    }
}


private struct SplitEntriesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    let onSave: () -> Void
    @State private var selected: Set<String> = []
    @State private var saving = false
    private var originals: [TimelineItem] {
        (item.originalItems ?? []).filter { $0.start < (item.end ?? .distantFuture) && ($0.end ?? .distantFuture) > item.start }
    }
    var body: some View {
        List {
            Section {
                Button(selected.count == originals.count ? "Deselect all" : "Select all") {
                    selected = selected.count == originals.count ? [] : Set(originals.map(\.id))
                }.accessibilityIdentifier("select-all-originals")
                ForEach(originals) { original in
                    Button {
                        if !selected.insert(original.id).inserted { selected.remove(original.id) }
                    } label: {
                        HStack(spacing: Layout.spacing) {
                            Image(systemName: selected.contains(original.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.green)
                            VStack(alignment: .leading, spacing: Layout.compact) {
                                Text(original.kind == .stay ? model.place(for: original)?.name ?? "Somewhere new" : original.kind == .journey ? original.mode.title : "Unrecorded interval")
                                    .foregroundStyle(Palette.ink)
                                Text(Display.range(original) + " · " + (original.duration() < 60 ? "Less than a minute" : Display.duration(original.duration()))).font(.subheadline).foregroundStyle(Palette.muted)
                            }
                        }.frame(minHeight: Layout.touchTarget)
                    }.buttonStyle(.plain).accessibilityAddTraits(selected.contains(original.id) ? .isSelected : [])
                        .accessibilityIdentifier("original-entry-\(original.id)")
                }
            } footer: { Text("Selected entries will stand alone. The others stay combined where possible.") }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Separate entries").navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Separate") {
                        saving = true
                        Task { if await model.split(item, selecting: selected) { onSave() }; saving = false }
                    }.disabled(selected.isEmpty).accessibilityIdentifier("confirm-split-entries")
                }
            }
    }
}
