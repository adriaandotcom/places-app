import SwiftUI
import PlacesCore
import CryptoKit
#if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
@preconcurrency import JournalingSuggestions
#endif

struct PastVisitSelection: Identifiable {
    let id = UUID()
    var title: String
    var date: DateInterval?
    var candidates: [PastVisitCandidate]
}

/// Both onboarding and the timeline use this entry point and the same review flow.
struct AddPastVisitsButton: View {
    @Environment(AppModel.self) private var model
    var day: Date = Date()
    @State private var picker = false
    @State private var selection: PastVisitSelection?
    @State private var loading = false
    @State private var unavailable = false
    var body: some View {
        button
            .sheet(item: $selection) { selection in
                NavigationStack { PastVisitReview(selection: selection, day: day) }
                    .environment(\.hasMainNavigation, false)
            }
            .alert("Suggestions aren’t available here", isPresented: $unavailable) {
                Button("OK", role: .cancel) {}
            } message: { Text("Open Places on your iPhone to choose events from Apple’s Journaling Suggestions.") }
    }

    private var button: some View {
        Button {
            #if DEBUG
            if model.uiTesting {
                selection = Self.fixture(day: day)
                return
            }
            #endif
            #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
            picker = true
            #else
            unavailable = true
            #endif
        } label: {
            HStack {
                if loading { ProgressView() }
                else { Image(systemName: "clock.arrow.circlepath") }
                Text(loading ? "Loading selected places…" : "Add past visits")
            }.frame(maxWidth: .infinity)
        }.buttonStyle(PrimaryButton()).disabled(loading)
            .accessibilityIdentifier("add-past-visits")
            #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
            .journalingSuggestionsPicker(isPresented: $picker) { suggestion in
                loading = true
                let selected = await Self.locations(from: suggestion)
                picker = false
                selection = selected
                loading = false
            }
            #endif
    }

    #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
    private static func locations(from suggestion: JournalingSuggestion) async -> PastVisitSelection {
        let individual = await suggestion.content(forType: JournalingSuggestion.Location.self)
        let groups = await suggestion.content(forType: JournalingSuggestion.LocationGroup.self)
        let undatedSelectionID = suggestion.items.map { $0.id.uuidString }.sorted().joined(separator: ",")
        var seen: Set<String> = []
        let candidates = (individual + groups.flatMap(\.locations)).compactMap { location -> PastVisitCandidate? in
            let coordinate = location.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            // Stable across individual/group representations and reopening the same suggestion.
            let identity = [location.place ?? "", location.city ?? "",
                coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "",
                location.date.map { String($0.timeIntervalSince1970) } ?? suggestion.date.map { "\($0.start.timeIntervalSince1970):\($0.end.timeIntervalSince1970)" } ?? undatedSelectionID]
                .joined(separator: "|")
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { return nil }
            return PastVisitCandidate(id: id, name: location.place ?? location.city ?? "", city: location.city,
                                      coordinate: coordinate, date: location.date)
        }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        return PastVisitSelection(title: suggestion.title, date: suggestion.date, candidates: candidates)
    }
    #endif

    #if DEBUG
    private static func fixture(day: Date) -> PastVisitSelection {
        let start = Calendar.current.startOfDay(for: min(day, Date().addingTimeInterval(-86_400))).addingTimeInterval(10 * 3600)
        return PastVisitSelection(title: "A day in the city", date: DateInterval(start: start, duration: 2 * 3600), candidates: [
            PastVisitCandidate(id: "fixture-past-visit", name: "Fixture Garden", city: "Fixture City",
                               coordinate: Coordinate(latitude: 52.36, longitude: 4.88), date: start)
        ])
    }
    #endif
}

private struct PastVisitReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: PastVisitSelection
    let day: Date
    @State private var drafts: [PastVisitDraft] = []
    @State private var context: PastVisitContext?
    @State private var reviewedAt = Date()
    @State private var saving = false
    @State private var error: String?
    @State private var showIssues = false
    private var plan: PastVisitPlan? { context.map { PastVisitPlan.make(drafts: drafts, context: $0, now: reviewedAt) } }

    var body: some View {
        Form {
            Section {
                Text(selection.title).font(BrandFont.title)
                if let date = selection.date {
                    Text("Event: \(date.start.formatted(date: .abbreviated, time: .shortened)) – \(date.end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
            }
            if let context {
                if drafts.isEmpty {
                    Section {
                        ContentUnavailableView("No places shared", systemImage: "mappin.slash",
                            description: Text("This event didn’t include locations. Choose another event with places selected."))
                    }
                }
                ForEach($drafts) { $draft in
                    PastVisitReviewRow(draft: $draft, places: context.places,
                        resolution: plan?.visits.first { $0.id == draft.id },
                        eventDate: selection.date, day: day, showIssues: showIssues)
                }
                if let plan, !drafts.isEmpty {
                    Section("Ready to add") {
                        if plan.count == 0 {
                            Text("No new visits yet").foregroundStyle(Palette.muted)
                        }
                        ForEach(plan.visits) { visit in
                            ForEach(visit.intervals, id: \.self) { interval in
                                VStack(alignment: .leading, spacing: Layout.compact) {
                                    Text(visit.place?.name ?? "Visit").font(.body.weight(.semibold))
                                    Text("\(interval.start.formatted(date: .abbreviated, time: .shortened)) – \(interval.end.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }.accessibilityIdentifier("past-visits-summary")
                }
            } else { Section { ProgressView("Loading your timeline…") } }
            if let error { Section { Text(error).foregroundStyle(Palette.warning).accessibilityIdentifier("past-visits-error") } }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Review past visits").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add visits") { Task { await save() } }
                        .disabled(saving || context == nil || drafts.isEmpty).accessibilityIdentifier("confirm-past-visits")
                }
            }.interactiveDismissDisabled(saving)
            .onChange(of: drafts) { _, _ in error = nil }
            .task {
                guard context == nil else { return }
                await reload()
                if let context { drafts = selection.candidates.map { PastVisitDraft(candidate: $0, places: context.places) } }
            }
    }
    private func reload() async {
        do {
            guard let store = model.store else { throw PastVisitImportError.invalidSelection }
            context = try await store.pastVisitContext()
        } catch { self.error = "Couldn’t load your timeline. Close this review and try again." }
    }
    private func save() async {
        guard let plan, plan.canImport else {
            showIssues = true
            error = "Check the selected places and times. Existing entries are kept unless you choose to replace them."
            return
        }
        saving = true; error = nil
        do {
            try await model.importPastVisits(drafts, reviewed: plan, at: reviewedAt)
            dismiss()
        } catch PastVisitImportError.timelineChanged {
            await reload()
            self.error = "Your timeline changed. Review the updated overlaps, then confirm again."
        } catch { self.error = "These visits couldn’t be saved. Nothing was added. Please try again." }
        saving = false
    }
}

private struct PastVisitReviewRow: View {
    @Binding var draft: PastVisitDraft
    let places: [Place]
    let resolution: PastVisitResolution?
    let eventDate: DateInterval?
    let day: Date
    let showIssues: Bool
    var body: some View {
        Section {
            Toggle(draft.candidate.name.isEmpty ? "Unnamed place" : draft.candidate.name, isOn: $draft.selected)
                .font(.body.weight(.semibold)).accessibilityIdentifier("select-past-visit-\(draft.id)")
            if draft.selected {
                if resolution?.alreadyAdded == true {
                    Label("Already added", systemImage: "checkmark.circle").foregroundStyle(Palette.muted)
                } else {
                    if let date = draft.candidate.date {
                        Text("Apple recorded a visit: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Picker("Place", selection: $draft.placeID) {
                        Text("New place").tag(String?.none)
                        ForEach(places) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if draft.placeID == nil {
                        LabeledContent("Name") {
                            TextField("Place name", text: $draft.name).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("past-visit-name")
                        }
                        if draft.candidate.coordinate == nil {
                            Text("Apple didn’t share coordinates. Choose a saved place or skip this visit.").font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                    PastVisitTimeField(title: "Arrival", value: $draft.arrival, suggested: eventDate?.start ?? day)
                    PastVisitTimeField(title: "Departure", value: $draft.departure, suggested: eventDate?.end ?? draft.arrival ?? day)
                    if let resolution, !resolution.conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: Layout.compact) {
                            Text("Overlaps your timeline").font(.subheadline.weight(.semibold))
                            ForEach(resolution.conflicts) { item in
                                Text("\(places.first { $0.id == item.placeID }?.name ?? (item.kind == .journey ? "Journey" : "Existing entry")) · \(Display.range(item))")
                                    .font(.footnote).foregroundStyle(Palette.muted)
                            }
                        }
                        Picker("Overlapping times", selection: $draft.replaceExisting) {
                            Text("Keep existing entries").tag(false)
                            Text("Replace with this visit").tag(true)
                        }.accessibilityIdentifier("past-visit-overlaps")
                        if resolution.intervals.isEmpty && resolution.issue == nil {
                            Text("This time is already covered. Nothing will be added for this visit.").font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                    if showIssues, let issue = resolution?.issue { Text(issue).font(.footnote).foregroundStyle(Palette.warning) }
                }
            }
        }
    }
}

private struct PastVisitTimeField: View {
    let title: String
    @Binding var value: Date?
    let suggested: Date
    @State private var choosing = false
    @State private var proposed = Date()
    var body: some View {
        if value != nil {
            DatePicker(title, selection: Binding(get: { value ?? suggested }, set: { value = $0 }), in: ...Date())
        } else if choosing {
            DatePicker(title, selection: $proposed, in: ...Date())
            Button("Use \(title.lowercased()) time") { value = proposed; choosing = false }
                .accessibilityIdentifier("use-past-visit-\(title.lowercased())")
        } else {
            Button("Set \(title.lowercased())") { proposed = min(suggested, Date()); choosing = true }
                .accessibilityIdentifier("set-past-visit-\(title.lowercased())")
        }
    }
}
