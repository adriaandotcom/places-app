import SwiftUI
import PlacesCore

struct RewindHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var month: Date
    @State private var summary: MonthlyRewind?
    @State private var failed = false
    private var isPreview: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                Menu {
                    ForEach(model.rewindMonths, id: \.self) { date in
                        Button(date.formatted(.dateTime.month(.wide).year())) { summary = nil; month = date }
                    }
                } label: {
                    HStack { Text(month.formatted(.dateTime.month(.wide).year())).font(BrandFont.title); Image(systemName: "chevron.down") }
                        .frame(minHeight: Layout.touchTarget)
                }.accessibilityLabel("Choose rewind month").accessibilityValue(month.formatted(.dateTime.month(.wide).year())).accessibilityIdentifier("rewind-month")
                VStack(alignment: .leading, spacing: Layout.spacing) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Palette.green).accessibilityHidden(true)
                    Text(isPreview ? "Your month,\nso far." : "A month\nworth revisiting.").font(BrandFont.hero)
                    Text(isPreview ? "A little preview. The full rewind is ready when the month ends." : "The places, people and little moments that made it yours.")
                        .font(BrandFont.body).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).modifier(CardSurface(padding: Layout.gutter, color: Palette.soft(0)))
                if let summary {
                    if summary.hasHighlights || !summary.reviewItems.isEmpty {
                        VStack(alignment: .leading, spacing: Layout.compact) {
                            Text(summary.reviewItems.isEmpty ? "One last look?" : "Fill in a few details").font(BrandFont.heading)
                            Text(summary.reviewItems.isEmpty ? "You can check your timeline before revisiting the highlights." : "\(summary.reviewItems.count) unnamed places or unknown intervals to look through. You can leave anything you don’t remember.")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                            NavigationLink {
                                TimelineReviewView(interval: summary.interval)
                            } label: { Label("Review timeline", systemImage: "checklist").frame(minHeight: Layout.touchTarget) }
                            .accessibilityIdentifier("rewind-review")
                        }.modifier(CardSurface())
                        if summary.hasHighlights {
                            NavigationLink { RewindStory(month: month) } label: { Text("Show my rewind") }
                                .buttonStyle(PrimaryButton()).accessibilityIdentifier("show-rewind")
                        }
                    } else {
                        EmptyState(symbol: "calendar", title: "A fresh page", message: "Your recorded places, trips and memories will bring this month to life.")
                    }
                    Text("Made on this iPhone from your recorded history.").font(.caption).foregroundStyle(Palette.muted)
                } else if failed {
                    Button("Try loading this month again") { Task { await load() } }
                } else { ProgressView().frame(maxWidth: .infinity) }
            }.padding(Layout.gutter)
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Monthly rewind").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(month.timeIntervalSince1970)-\(model.historyRevision)") { await load() }
    }
    private func load() async {
        failed = false
        do {
            let value = try await model.store?.monthlyRewind(for: month)
            guard !Task.isCancelled else { return }
            summary = value
        } catch { if !Task.isCancelled { failed = true } }
    }
}

struct TimelineReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let interval: DateInterval
    var weekly = false
    @State private var items: [TimelineItem] = []
    @State private var selected: TimelineItem?
    @State private var loading = true
    @State private var failed = false
    @State private var showAll = false
    private var visible: [TimelineItem] { showAll ? items : TimelineReview.items(in: items, places: model.places) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                Text(weekly ? "A little catch-up." : "Make it yours.").font(BrandFont.hero)
                Text(interval.start.formatted(date: .abbreviated, time: .omitted) + " – " + min(interval.end, Date()).formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline).foregroundStyle(Palette.muted)
                Picker("Timeline entries", selection: $showAll) {
                    Text("To review").tag(false)
                    Text("All entries").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("rewind-review-filter")
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if failed { Button("Try again") { Task { await load() } } }
                else if visible.isEmpty {
                    EmptyState(symbol: "checkmark.circle", title: showAll ? "No entries yet" : "All caught up", message: showAll ? "There is no timeline recorded for this period." : "No unnamed places or unreviewed gaps in this period.")
                } else {
                    LazyVStack(alignment: .leading, spacing: Layout.compact) {
                        ForEach(visible) { item in
                            Button { selected = item } label: {
                                VStack(alignment: .leading, spacing: Layout.compact) {
                                    Text(item.start.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(Palette.muted)
                                    TimelineRow(item: item, place: model.place(for: item))
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("review-entry-\(item.id)")
                        }
                    }
                }
            }.padding(Layout.gutter)
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Review timeline").navigationBarTitleDisplayMode(.inline)
            .toolbar { if weekly { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .task(id: model.historyRevision) { await load() }
            .sheet(item: $selected) { item in NavigationStack { TimelineDetail(item: item) }.environment(\.hasMainNavigation, false) }
    }
    private func load() async {
        do {
            let values = try await model.store?.timeline(in: interval) ?? []
            guard !Task.isCancelled else { return }
            items = values; loading = false; failed = false
        } catch { if !Task.isCancelled { loading = false; failed = true } }
    }
}

private enum RewindPage: String, CaseIterable { case places, favourite, destinations, journeys, company, memories }

struct RewindStory: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let month: Date
    @State private var summary: MonthlyRewind?
    @State private var index = 0
    @State private var failed = false
    private func pages(_ value: MonthlyRewind) -> [RewindPage] {
        RewindPage.allCases.filter { page in
            switch page {
            case .places: true
            case .favourite: !value.places.isEmpty
            case .destinations: !value.cities.isEmpty || !value.countries.isEmpty || !value.trips.isEmpty
            case .journeys: !value.journeys.isEmpty
            case .company: !value.people.isEmpty
            case .memories: true
            }
        }
    }
    var body: some View {
        Group {
            if let summary {
                let cards = pages(summary)
                VStack(spacing: Layout.spacing) {
                    HStack(spacing: Layout.compact) {
                        ForEach(cards.indices, id: \.self) { i in
                            Capsule().fill(i <= index ? Palette.green : Palette.line).frame(height: 4)
                        }
                    }.padding(.horizontal, Layout.gutter).accessibilityHidden(true)
                    TabView(selection: $index) {
                        ForEach(Array(cards.enumerated()), id: \.element) { i, page in
                            RewindStoryCard(page: page, summary: summary).padding(.horizontal, Layout.gutter).tag(i)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never)).accessibilityIdentifier("rewind-pages")
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { index = max(0, index - 1) }
                            .labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget).disabled(index == 0)
                        Spacer()
                        Text("\(index + 1) of \(cards.count)").font(.subheadline).accessibilityIdentifier("rewind-progress")
                        Spacer()
                        Button(index == cards.count - 1 ? "Finish" : "Next", systemImage: index == cards.count - 1 ? "checkmark" : "chevron.right") {
                            if index == cards.count - 1 { dismiss() } else { index += 1 }
                        }.labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget).accessibilityIdentifier("rewind-next")
                    }.modifier(FloatingIsland()).padding(.horizontal, Layout.gutter).padding(.bottom, Layout.compact)
                }
            } else if failed { Button("Try again") { Task { await load() } } }
            else { ProgressView() }
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle(month.formatted(.dateTime.month(.wide))).navigationBarTitleDisplayMode(.inline)
            .task(id: model.historyRevision) { await load() }
    }
    private func load() async {
        do {
            let result = try await model.store?.monthlyRewind(for: month)
            guard !Task.isCancelled else { return }
            if let result { index = min(index, pages(result).count - 1) }
            summary = result; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }
}

private struct RewindStoryCard: View {
    let page: RewindPage
    let summary: MonthlyRewind
    private var color: Int { RewindPage.allCases.firstIndex(of: page) ?? 0 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                switch page {
                case .places:
                    Image(systemName: "mappin.and.ellipse").font(.largeTitle).accessibilityHidden(true)
                    Text("Your month\nin places.").font(BrandFont.hero)
                    Text("\(summary.places.count)").font(BrandFont.rewindNumber).accessibilityIdentifier("rewind-place-count")
                    Text(summary.places.count == 1 ? "named place in your story" : "named places in your story").font(BrandFont.title)
                    Text("Across \(summary.recordedDays) recorded \(summary.recordedDays == 1 ? "day" : "days").").font(BrandFont.body)
                case .favourite:
                    if let first = summary.places.first {
                        PlaceIcon(symbol: first.place.symbol, colorIndex: first.place.colorIndex, customColorHex: first.place.customColorHex, size: Layout.iconTile)
                        Text("A familiar\nfavourite.").font(BrandFont.hero)
                        Text(first.place.name).font(BrandFont.hero)
                        Text("Part of \(first.days) of your recorded \(first.days == 1 ? "day" : "days") this month.").font(BrandFont.body)
                        ForEach(summary.places.dropFirst().prefix(3)) { item in
                            HStack { Text(item.place.name); Spacer(); Text("\(item.days) d").monospacedDigit() }.font(BrandFont.body)
                        }
                    }
                case .destinations:
                    Image(systemName: "suitcase.rolling").font(.largeTitle).accessibilityHidden(true)
                    Text("A change\nof scenery.").font(BrandFont.hero)
                    if !summary.countries.isEmpty { Text(summary.countries.joined(separator: " · ")).font(BrandFont.title) }
                    if !summary.cities.isEmpty { Text(summary.cities.joined(separator: " · ")).modifier(MemoryReadingStyle()) }
                    ForEach(summary.trips) { trip in
                        NavigationLink { TripDetail(tripID: trip.id) } label: {
                            InfoRow(symbol: "suitcase.rolling", title: trip.title, subtitle: "Revisit this trip", colorIndex: color, showsDisclosure: true)
                        }.buttonStyle(.plain)
                    }
                case .journeys:
                    Image(systemName: "figure.walk").font(.largeTitle).accessibilityHidden(true)
                    Text("On the\nmove.").font(BrandFont.hero)
                    ForEach(summary.journeys.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { mode in
                        HStack {
                            Image(systemName: mode.symbol).frame(width: Layout.touchTarget)
                            Text(mode.title)
                            Spacer()
                            Text(Display.duration(summary.journeys[mode] ?? 0)).font(BrandFont.title)
                        }.frame(minHeight: Layout.touchTarget)
                    }
                    Text("Time in recorded journeys. Unknown intervals aren’t included.").font(.caption).foregroundStyle(Palette.muted)
                case .company:
                    Image(systemName: "person.2").font(.largeTitle).accessibilityHidden(true)
                    Text("Better\ntogether.").font(BrandFont.hero)
                    PersonAvatarGroup(personIDs: summary.people.map(\.id), border: Palette.soft(color))
                    Text(summary.people.map(\.name).joined(separator: ", ")).modifier(MemoryReadingStyle())
                    Text("The people you added to this month’s trips and memories.").font(.subheadline).foregroundStyle(Palette.muted)
                case .memories:
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).accessibilityHidden(true)
                    Text("The little\nthings stay.").font(BrandFont.hero)
                    Text("\(summary.memories.count) \(summary.memories.count == 1 ? "memory" : "memories") · \(summary.photoIDs.count) \(summary.photoIDs.count == 1 ? "photo" : "photos")").font(BrandFont.title)
                    if !summary.photoIDs.isEmpty {
                        PhotoGrid(items: summary.photoIDs.prefix(6).map { PhotoReference(id: $0) }) { photo in StoredPhoto(id: photo.id, thumbnail: true) }
                    }
                    if let note = summary.memories.first(where: { !$0.text.isEmpty }) {
                        Text(note.text).modifier(MemoryReadingStyle())
                    } else { Text("An ordinary day can be a lovely memory. Add a note or photo to a place or trip whenever you like.").modifier(MemoryReadingStyle()) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(Layout.gutter)
        }.background(Palette.soft(color), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
    }
}
