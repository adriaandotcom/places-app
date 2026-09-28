import SwiftUI
import PlacesCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack { TimelineView().toolbar(.hidden, for: .tabBar) }
                .id(model.navigationRoots[.timeline]?.uuidString ?? "timeline")
                .tabItem { Label("Timeline", systemImage: AppTab.timeline.symbol) }.tag(AppTab.timeline)
            NavigationStack { MapScreen().toolbar(.hidden, for: .tabBar) }
                .id(model.navigationRoots[.map]?.uuidString ?? "map")
                .tabItem { Label("Map", systemImage: AppTab.map.symbol) }.tag(AppTab.map)
            NavigationStack { PlacesView().toolbar(.hidden, for: .tabBar) }
                .id(model.navigationRoots[.places]?.uuidString ?? "places")
                .tabItem { Label("Places", systemImage: AppTab.places.symbol) }.tag(AppTab.places)
            NavigationStack { SearchView().toolbar(.hidden, for: .tabBar) }
                .id(model.navigationRoots[.search]?.uuidString ?? "search")
                .tabItem { Label("Search", systemImage: AppTab.search.symbol) }.tag(AppTab.search)
        }
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .bottom) {
            MainNavigationIsland()
        }
        .background(Palette.background)
        .environment(\.hasMainNavigation, true)
        .sheet(item: Binding(get: { model.rewindRequest }, set: { model.rewindRequest = $0 })) { request in
            NavigationStack {
                if request.reviewWeek { TimelineReviewView(interval: DateInterval(start: request.month, end: max(request.month, min(Date(), Calendar.current.date(byAdding: .day, value: 7, to: request.month)!))), weekly: true) }
                else { RewindHome(month: request.month) }
            }.environment(\.hasMainNavigation, false)
        }
    }
}

private struct MainNavigationIsland: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { model.openMainTab(tab) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol).font(.system(size: 20, weight: .semibold))
                        if model.selectedTab == tab && !typeSize.isAccessibilitySize {
                            Text(tab.title).font(.subheadline.weight(.semibold)).fixedSize()
                        }
                    }.frame(maxWidth: model.selectedTab == tab && !typeSize.isAccessibilitySize ? nil : .infinity)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.navigationItemHeight)
                        .padding(.horizontal, model.selectedTab == tab ? 10 : 0)
                        .foregroundStyle(model.selectedTab == tab ? Palette.navigationSelectedInk : Palette.navigationInk)
                        .background(model.selectedTab == tab ? Palette.navigationSelected : .clear, in: Capsule())
                        .contentShape(Rectangle())
                        .fixedSize(horizontal: model.selectedTab == tab && !typeSize.isAccessibilitySize, vertical: false)
                }.buttonStyle(.plain).accessibilityLabel(tab.title)
                    .layoutPriority(model.selectedTab == tab ? 1 : 0)
                    .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }.modifier(FloatingIsland())
            .padding(.horizontal, Layout.gutter).padding(.top, Layout.compact).padding(.bottom, 4)
    }
}

struct SettingsToolbar: ToolbarContent {
    @State private var open = false
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "slider.horizontal.3") { open = true }
                .labelStyle(.iconOnly).foregroundStyle(Palette.ink).accessibilityIdentifier("open-settings")
                .sheet(isPresented: $open) { NavigationStack { SettingsView() } }
        }
    }
}

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: TimelineItem?
    @State private var showDate = false
    @State private var addPlace = false
    private var title: String {
        if Calendar.current.isDateInToday(model.selectedDay) { return "Today" }
        if Calendar.current.isDateInYesterday(model.selectedDay) { return "Yesterday" }
        return model.selectedDay.formatted(.dateTime.weekday(.wide))
    }
    private var placeCount: Int { Set(model.timeline.filter { $0.kind == .stay }.map { $0.placeID ?? "unknown-\($0.id)" }).count }

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var dayProgress: CGFloat = 0
    @State private var settings = false
    private var heading: String {
        if model.timeline.isEmpty { return "Your day,\nremembered." }
        if placeCount == 1 { return "\(title) you were\nat 1 place" }
        if placeCount == 0 { return "\(title)’s timeline" }
        return "\(title) you went\nto \(placeCount) places"
    }
    var body: some View {
        VStack(spacing: Layout.spacing) {
            VStack(alignment: .leading, spacing: Layout.compact) {
                HStack(alignment: .top) {
                    Text(heading).font(typeSize.isAccessibilitySize ? BrandFont.title : BrandFont.heading)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("timeline-heading")
                    Spacer(minLength: Layout.compact)
                    Button("Settings", systemImage: "slider.horizontal.3") { settings = true }
                        .labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget)
                        .accessibilityIdentifier("open-settings")
                }
                HStack {
                    Text(model.selectedDay.formatted(.dateTime.month(.wide).year())).font(.subheadline).foregroundStyle(Palette.muted)
                    Spacer()
                    Button { model.rewindRequest = RewindRequest(month: model.defaultRewindMonth) } label: {
                        Label("Rewind", systemImage: "sparkles").font(.subheadline.weight(.semibold)).frame(minHeight: Layout.touchTarget)
                    }.accessibilityIdentifier("open-rewind")
                    Button { showDate = true } label: { Image(systemName: "calendar").frame(width: 44, height: 44) }
                        .accessibilityLabel("Choose date")
                }
                TimelineDayStrip(progress: dayProgress)
            }.padding(.horizontal, Layout.gutter).padding(.top, Layout.compact)
            TimelinePager(progress: $dayProgress, select: { selected = $0 }, addPlace: { addPlace = true })
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { NavigationStack { SettingsView() } }
            .sheet(item: $selected) { item in NavigationStack { TimelineDetail(item: item) }.environment(\.hasMainNavigation, false) }
            .sheet(isPresented: $addPlace) { NavigationStack { PlaceEditor() } }
            .sheet(isPresented: $showDate) { NavigationStack { HistoryDatePicker(timelineOnly: true) } }
    }
}

struct TimelineRow: View {
    let item: TimelineItem
    let place: Place?
    var body: some View {
        if item.kind == .stay {
            HStack(alignment: .top, spacing: 14) {
                PlaceIcon(symbol: place?.symbol ?? "mappin", colorIndex: place?.colorIndex ?? 4)
                VStack(alignment: .leading, spacing: 7) {
                    Text(place?.name ?? "Somewhere new").font(BrandFont.title).multilineTextAlignment(.leading)
                    Text(Display.range(item)).font(.subheadline).foregroundStyle(Palette.muted)
                    HStack(spacing: 5) {
                        if item.isUserEdited { Image(systemName: "checkmark.circle.fill") }
                        Text(Display.duration(item.duration()))
                    }.font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Palette.muted).padding(.top, 16)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.soft(place?.colorIndex ?? 4), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 15) {
                DottedLine().stroke(Palette.muted.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                    .frame(width: 2).padding(.leading, 38).accessibilityHidden(true)
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .gap ? (item.connection == nil ? "questionmark.circle" : "point.topleft.down.to.point.bottomright.curvepath") : item.mode.symbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.kind == .gap ? (item.connection == nil ? "An unknown interval" : "Between recorded locations") : item.mode.title).font(.subheadline.weight(.semibold))
                        Text(Display.duration(item.duration())).font(.caption).foregroundStyle(Palette.muted)
                        if item.kind == .gap && item.connection != nil {
                            Text("Path not recorded").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2)
                }.padding(.vertical, 10).padding(.horizontal, 12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
            }.frame(minHeight: 78).padding(.trailing, 16).accessibilityElement(children: .combine)
        }
    }
}
private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) } }
}
