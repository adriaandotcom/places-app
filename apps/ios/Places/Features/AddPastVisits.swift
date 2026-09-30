import SwiftUI
import PlacesCore

struct PastVisitReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: AppleSuggestionSelection
    let day: Date
    let onSaved: (String) -> Void
    let chooseNext: () -> Void
    @State private var epoch: Int?
    @State private var photoIDs: Set<String> = []
    @State private var memoryVisitID: String?
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
                            description: Text("This event didn’t include locations."))
                        Button("Choose another suggestion", action: chooseNext)
                    }
                }
                ForEach($drafts) { $draft in
                    PastVisitReviewRow(draft: $draft, places: context.places,
                        resolution: plan?.visits.first { $0.id == draft.id },
                        showIssues: showIssues, sourceName: selection.sourceName)
                }
                if let plan, !drafts.isEmpty {
                    Section("Ready to add") {
                        if plan.count == 0 {
                            Text(plan.memoryVisits.isEmpty ? "No new visits yet" : "Visits already in your timeline").foregroundStyle(Palette.muted)
                            Button("Choose another suggestion", action: chooseNext)
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
                if !photoIDs.isEmpty {
                    Section("Memory") {
                        let visits = plan?.memoryVisits ?? []
                        if visits.count > 1 {
                            Picker("Save photos at", selection: $memoryVisitID) {
                                ForEach(visits) { visit in Text(visit.place?.name ?? "Visit").tag(Optional(visit.id)) }
                            }
                        } else if let place = visits.first?.place { LabeledContent("Place", value: place.name) }
                        PhotoGrid(items: selection.photos.filter { photoIDs.contains($0.id) }, remove: { photoIDs.remove($0.id) }) { photo in
                            DraftPhotoThumbnail(id: photo.id, files: selection.photos)
                        }.accessibilityIdentifier("suggestion-photos")
                    }
                }
            } else { Section { ProgressView("Loading your timeline…") } }
            if let error { Section { Text(error).foregroundStyle(Palette.warning).accessibilityIdentifier("past-visits-error") } }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Review past visits").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : plan?.count == 0 && memoryVisitID != nil && !photoIDs.isEmpty ? "Add memory" : "Add visits") { Task { await save() } }
                        .disabled(saving || context == nil || drafts.isEmpty).accessibilityIdentifier("confirm-past-visits")
                }
            }.interactiveDismissDisabled(saving)
            .onChange(of: drafts) { _, _ in error = nil }
            .onChange(of: plan) { _, _ in updateMemoryPlace() }
            .task {
                guard context == nil else { return }
                epoch = model.memoryEpoch
                await reload()
                if let context {
                    drafts = selection.candidates.map {
                        PastVisitDraft(candidate: $0, places: context.places,
                            eventDate: selection.candidates.count == 1 ? selection.date : nil,
                            fallbackDate: min(selection.date?.start ?? day, reviewedAt.addingTimeInterval(-3600)), now: reviewedAt)
                    }
                    photoIDs = Set(selection.photos.map(\.id))
                    updateMemoryPlace()
                }
            }
    }
    private func updateMemoryPlace() {
        let visits = plan?.memoryVisits ?? []
        if !visits.contains(where: { $0.id == memoryVisitID }) { memoryVisitID = visits.first?.id }
    }
    private func reload() async {
        do {
            guard let store = model.store else { throw PastVisitImportError.invalidSelection }
            context = try await store.pastVisitContext()
        } catch { self.error = "Couldn’t load your timeline. Close this review and try again." }
    }
    private func save() async {
        guard let plan, plan.canImport || (plan.visits.allSatisfy { $0.issue == nil } && memoryVisitID != nil && !photoIDs.isEmpty) else {
            showIssues = true
            error = "Check the selected places and times. Existing entries are kept unless you choose to replace them."
            return
        }
        saving = true; error = nil
        do {
            guard let epoch else { throw CancellationError() }
            let photos = selection.photos.filter { photoIDs.contains($0.id) }
            let memory = photos.isEmpty ? nil : memoryVisitID.map { PastVisitMemory(visitID: $0, suggestionID: selection.id, photos: photos) }
            if !photos.isEmpty && memory == nil { throw PastVisitImportError.invalidSelection }
            try await model.importPastVisits(drafts, reviewed: plan, at: reviewedAt, memory: memory, epoch: epoch)
            onSaved(memory == nil ? "Visits added" : plan.count == 0 ? "Memory added" : "Visits and memory added")
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
    let showIssues: Bool
    let sourceName: String
    var body: some View {
        Section {
            Toggle(draft.candidate.name.isEmpty ? "Unnamed place" : draft.candidate.name, isOn: $draft.selected)
                .font(.body.weight(.semibold)).accessibilityIdentifier("select-past-visit-\(draft.id)")
            if draft.selected {
                if resolution?.alreadyAdded == true {
                    Label("Already added", systemImage: "checkmark.circle").foregroundStyle(Palette.muted)
                } else {
                    if let date = draft.candidate.date {
                        Text("\(sourceName) recorded a location: \(date.formatted(date: .abbreviated, time: .shortened))")
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
                    DatePicker("Arrival", selection: Binding(get: { draft.arrival ?? Date() }, set: { date in
                        draft.arrival = date
                        if draft.departure.map({ $0 <= date }) != false { draft.departure = min(date.addingTimeInterval(3600), Date()) }
                    }), in: ...Date()).accessibilityIdentifier("past-visit-arrival")
                    DatePicker("Departure", selection: Binding(get: { draft.departure ?? Date() }, set: { draft.departure = $0 }), in: ...Date())
                        .accessibilityIdentifier("past-visit-departure")
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
