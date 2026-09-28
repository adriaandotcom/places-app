import SwiftUI
import PlacesCore

struct TripsList: View {
    @Environment(AppModel.self) private var model
    @State private var hidden = false
    var body: some View {
        let trips = model.memories.trips.filter { hidden ? $0.hidden : !$0.hidden }
        if model.memories.trips.contains(where: \.hidden) {
            HStack { Spacer(); Button(hidden ? "Show trips" : "Hidden") { hidden.toggle() }.font(.subheadline) }
                .frame(minHeight: Layout.touchTarget)
        }
        if trips.isEmpty {
            EmptyState(symbol: "suitcase.rolling", title: "Your time away", message: "Your trips will appear here. You can also add one yourself.")
        }
        ForEach(trips) { trip in TripLink(trip: trip) }
    }
}

struct TripLink: View {
    let trip: Trip
    var body: some View {
        NavigationLink { TripDetail(tripID: trip.id) } label: {
            InfoRow(symbol: "suitcase.rolling.fill", title: trip.title, subtitle: TripDisplay.dates(trip), colorIndex: 1)
        }.buttonStyle(.plain).accessibilityIdentifier("trip-\(trip.id)")
    }
}
enum TripDisplay {
    static func dates(_ trip: Trip) -> String {
        trip.start.formatted(date: .abbreviated, time: .omitted) + " – " + (trip.end?.formatted(date: .abbreviated, time: .omitted) ?? "now")
    }
}

struct TripDetail: View {
    @Environment(AppModel.self) private var model
    let tripID: String
    @State private var editing = false
    @State private var items: [TimelineItem] = []
    @State private var routes: [RoutePoint] = []
    @State private var loadError = false
    private var trip: Trip? { model.memories.trips.first { $0.id == tripID } }
    var body: some View {
        ScrollView {
            if let trip {
                VStack(alignment: .leading, spacing: Layout.spacing) {
                    Text(trip.title).font(BrandFont.hero)
                    Text(TripDisplay.dates(trip)).font(.subheadline).foregroundStyle(Palette.muted)
                    PersonAvatarGroup(personIDs: trip.personIDs)
                    MemorySection(context: .trip(trip))
                    MapPreviewCard(items: items, routePoints: routes)
                    if loadError { Text("The trip’s visits couldn’t be loaded. Reopen this trip to try again.").foregroundStyle(Palette.muted) }
                    let places = model.places.filter { place in items.contains { $0.kind == .stay && $0.placeID == place.id } }
                    if !places.isEmpty {
                        SectionHeading(title: "Places on this trip")
                        ForEach(places) { place in
                            NavigationLink {
                                TripPlaceVisits(trip: trip, place: place, items: items.filter { $0.kind == .stay && $0.placeID == place.id })
                            } label: { SavedPlaceRow(place: place, subtitle: "View visits & memories", card: true) }.buttonStyle(.plain)
                        }
                    }
                }.padding(Layout.gutter)
            }
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit trip", systemImage: "pencil") { editing = true }.accessibilityIdentifier("edit-trip") } }
            .task(id: model.historyRevision) {
                guard let trip, let store = model.store else { return }
                let interval = trip.interval()
                do {
                    let visits = try await store.timeline(in: interval)
                    let points = try await store.routePoints(from: interval.start, to: interval.end)
                    guard !Task.isCancelled else { return }
                    items = visits; routes = points; loadError = false
                } catch { loadError = true }
            }
            .sheet(isPresented: $editing) { if let trip { NavigationStack { TripEditor(trip: trip) } } }
    }
}

private struct TripPlaceVisits: View {
    @Environment(AppModel.self) private var model
    let trip: Trip
    let place: Place
    let items: [TimelineItem]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                Text(place.name).font(BrandFont.hero)
                Text(trip.title).foregroundStyle(Palette.muted)
                NavigationLink("About this place") { PlaceDetail(placeID: place.id) }.frame(minHeight: Layout.touchTarget)
                ForEach(items) { item in
                    NavigationLink { TimelineDetail(item: item) } label: {
                        InfoRow(symbol: "clock", title: item.start.formatted(date: .abbreviated, time: .omitted), subtitle: Display.range(item), colorIndex: place.colorIndex)
                    }.buttonStyle(.plain)
                }
                ForEach(model.memories.memories.filter { $0.placeID == place.id && $0.belongs(to: trip) }) { memory in MemoryCard(memory: memory) }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
    }
}

struct TripEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Trip
    @State private var trip: Trip
    @State private var end: Date
    @State private var ongoing: Bool
    @State private var saving = false
    @State private var error: String?
    @State private var epoch: Int?
    init(trip: Trip = Trip(title: "", start: Calendar.current.startOfDay(for: Date()))) {
        original = trip; _trip = State(initialValue: trip)
        _end = State(initialValue: trip.end ?? Date()); _ongoing = State(initialValue: trip.end == nil)
    }
    var body: some View {
        Form {
            Section {
                TextField("Trip name", text: $trip.title).accessibilityIdentifier("trip-name")
                DateRangeFields(start: $trip.start, end: $end, ongoing: $ongoing, components: [.date, .hourAndMinute], endTitle: "Until")
            }
            Section {
                PeopleSelectionField(selection: $trip.personIDs).accessibilityIdentifier("trip-people")
            }
            if model.memories.trips.contains(where: { $0.id == trip.id }) {
                Section { Toggle("Hide this trip", isOn: $trip.hidden) } footer: { Text("Hidden trips keep their notes and photos. You can find them under Hidden in Trips.") }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Trip").navigationBarTitleDisplayMode(.inline)
            .onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .modifier(EditorControls(saving: saving,
                canSave: !trip.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (ongoing || end > trip.start),
                error: $error, errorTitle: "Couldn’t save trip", saveIdentifier: "save-trip", cancel: { dismiss() }, save: save))
    }
    private func save() {
        guard let epoch else { return }
        var value = trip
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.end = ongoing ? nil : end
        value.datesEdited = value.datesEdited || value.start != original.start || value.end != original.end
        value.titleEdited = value.titleEdited || value.title != original.title
        let saved = value
        saving = true
        Task {
            do { try await model.changeMemories(epoch: epoch) { try await $0.saveTrip(saved) }; dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
