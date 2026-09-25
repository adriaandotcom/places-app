import SwiftUI
import PlacesCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
        TabView(selection: $model.selectedTab) {
            NavigationStack { TimelineView().toolbar(.hidden, for: .tabBar) }
                .tabItem { Label("Timeline", systemImage: AppTab.timeline.symbol) }.tag(AppTab.timeline)
            NavigationStack { MapScreen().toolbar(.hidden, for: .tabBar) }
                .tabItem { Label("Map", systemImage: AppTab.map.symbol) }.tag(AppTab.map)
            NavigationStack { PlacesView().toolbar(.hidden, for: .tabBar) }
                .tabItem { Label("Places", systemImage: AppTab.places.symbol) }.tag(AppTab.places)
            NavigationStack { SearchView().toolbar(.hidden, for: .tabBar) }
                .tabItem { Label("Search", systemImage: AppTab.search.symbol) }.tag(AppTab.search)
        }
        .toolbar(.hidden, for: .tabBar)
            HStack(spacing: 4) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button { model.selectedTab = tab } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.symbol).font(.system(size: 20, weight: .semibold))
                            if model.selectedTab == tab && !typeSize.isAccessibilitySize {
                                Text(tab.title).font(.subheadline.weight(.semibold)).fixedSize()
                            }
                        }.frame(maxWidth: model.selectedTab == tab && !typeSize.isAccessibilitySize ? nil : .infinity)
                            .frame(minWidth: 44, minHeight: 48)
                            .padding(.horizontal, model.selectedTab == tab ? 10 : 0)
                            .foregroundStyle(model.selectedTab == tab ? Color(red: 0.19, green: 0.16, blue: 0.12) : .white.opacity(0.85))
                            .background(model.selectedTab == tab ? Color(red: 0.98, green: 0.96, blue: 0.92) : .clear, in: Capsule())
                            .contentShape(Rectangle())
                            .fixedSize(horizontal: model.selectedTab == tab && !typeSize.isAccessibilitySize, vertical: false)
                    }.buttonStyle(.plain).accessibilityLabel(tab.title)
                        .layoutPriority(model.selectedTab == tab ? 1 : 0)
                        .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                        .accessibilityIdentifier("tab-\(tab.rawValue)")
                }
            }.padding(6).background(Color(red: 0.16, green: 0.14, blue: 0.11), in: Capsule())
                .padding(.horizontal, Layout.gutter).padding(.top, 8).padding(.bottom, 4)
                .background(Palette.background)
        }.background(Palette.background)
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
    @State private var visibleWeekEnd = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(spacing: Layout.spacing) {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                HStack {
                    Label(model.tracking.state.title, systemImage: model.tracking.state == .paused ? "pause.circle" : "location.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button { showDate = true } label: { Image(systemName: "calendar").frame(width: 44, height: 44) }
                        .accessibilityLabel("Choose date")
                }
                Text(model.timeline.isEmpty ? "Your day,\nremembered." : "\(title) you went\nto \(placeCount) \(placeCount == 1 ? "place" : "places")")
                    .font(typeSize.isAccessibilitySize ? BrandFont.title : BrandFont.hero)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("timeline-heading")
                dayPicker
            }.padding(.horizontal, Layout.gutter)
            TimelinePager(select: { selected = $0 }, addPlace: { addPlace = true })
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Places").navigationBarTitleDisplayMode(.inline)
            .toolbar { SettingsToolbar() }
            .sheet(item: $selected) { item in NavigationStack { TimelineDetail(item: item) } }
            .sheet(isPresented: $addPlace) { NavigationStack { PlaceEditor() } }
            .sheet(isPresented: $showDate) {
                NavigationStack {
                    DatePicker("Date", selection: Binding(get: { model.selectedDay }, set: { model.selectDay($0) }), in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).padding().navigationTitle("Your history")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: model.selectedDay, initial: true) { _, selected in
                let start = Calendar.current.date(byAdding: .day, value: -6, to: visibleWeekEnd)!
                let day = Calendar.current.startOfDay(for: selected)
                if day < start { visibleWeekEnd = Calendar.current.date(byAdding: .day, value: 6, to: day)! }
                else if day > visibleWeekEnd { visibleWeekEnd = day }
            }
    }

    private var dayPicker: some View {
        HStack(spacing: 7) {
            ForEach(-6...0, id: \.self) { offset in
                let day = Calendar.current.date(byAdding: .day, value: offset, to: visibleWeekEnd)!
                let selected = Calendar.current.isDate(day, inSameDayAs: model.selectedDay)
                Button { model.selectDay(day) } label: {
                    VStack(spacing: 8) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                        Text(day.formatted(.dateTime.day())).font(BrandFont.title)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(selected ? Palette.background : Palette.ink)
                        .background(selected ? Palette.ink : Palette.paper, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityIdentifier("timeline-day-\(offset)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(day > Calendar.current.startOfDay(for: Date()))
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline date")
            .accessibilityValue(model.selectedDay.formatted(date: .complete, time: .omitted))
            .accessibilityAdjustableAction { direction in model.shiftDay(direction == .increment ? 1 : -1) }
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
