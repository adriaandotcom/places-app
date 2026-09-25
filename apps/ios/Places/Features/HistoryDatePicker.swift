import SwiftUI
import PlacesCore

struct DaySwipe: ViewModifier {
    let change: (Int) -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            let x = value.translation.width, y = value.translation.height
            guard abs(x) > 70, abs(x) > abs(y) * 2 else { return }
            change(x < 0 ? 1 : -1)
        })
    }
}

struct MapDateBar: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    private var anchor: Date { model.mapPeriod?.interval.start ?? model.selectedDay }
    private var canGoForward: Bool { Calendar.current.startOfDay(for: anchor) < Calendar.current.startOfDay(for: Date()) }
    private var title: String {
        model.mapPeriod?.title ?? (Calendar.current.isDateInToday(model.selectedDay) ? "Today" : model.selectedDay.formatted(date: .abbreviated, time: .omitted))
    }
    var body: some View {
        HStack(spacing: Layout.compact) {
            Button { model.shiftDay(-1, fromMap: true) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous day").accessibilityIdentifier("map-previous-day")
            Button { choosing = true } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(BrandFont.title)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    if let period = model.mapPeriod {
                        Text(period.dateLabel)
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Choose date or period, \(title)").accessibilityIdentifier("map-period-picker")
            Button { model.shiftDay(1, fromMap: true) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(!canGoForward).opacity(canGoForward ? 1 : 0.3)
                .accessibilityLabel("Next day").accessibilityIdentifier("map-next-day")
        }.padding(.horizontal, Layout.compact).padding(.vertical, Layout.compact)
            .background(Palette.paper).contentShape(Rectangle())
            .modifier(DaySwipe { model.shiftDay($0, fromMap: true) })
            .sheet(isPresented: $choosing) { NavigationStack { HistoryDatePicker() } }
    }
}

struct HistoryDatePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var range = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var periods: [HistoryPeriod] = []
    @State private var loadError = false
    private let calendar = Calendar.current
    var body: some View {
        Form {
            Section {
                Picker("Selection", selection: $range) {
                    Text("Day").tag(false); Text("Period").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("history-selection-mode")
                if range {
                    DatePicker("From", selection: $start, in: ...Date(), displayedComponents: .date)
                    DatePicker("Through", selection: $end, in: start...max(start, Date()), displayedComponents: .date)
                } else {
                    DatePicker("Day", selection: $start, in: ...Date(), displayedComponents: .date).datePickerStyle(.graphical)
                }
                Button(range ? "Show period" : "Show day") { apply() }.accessibilityIdentifier("show-history-period")
            }
            Section("Quick dates") {
                Button("Today") { model.selectDay(Date()); dismiss() }
                Button("Last 7 days") {
                    selectDays(from: calendar.date(byAdding: .day, value: -6, to: Date())!, through: Date(), title: "Last 7 days")
                }
                Button("This month") { selectDays(from: calendar.dateInterval(of: .month, for: Date())!.start, through: Date(), title: "This month") }
            }
            Section("Your visits") {
                if loadError { Text("Visits couldn’t be loaded. You can still choose dates above.") }
                else if periods.isEmpty {
                    Text("Add a city or country to a saved place to see visits here.").foregroundStyle(Palette.muted)
                    NavigationLink("City & country lookup") { CityLookupSettings() }
                } else {
                    ForEach(periods) { period in
                        Button { model.selectPeriod(period); dismiss() } label: {
                            HStack(spacing: Layout.spacing) {
                                Image(systemName: period.isCountry ? "globe.europe.africa" : "building.2").frame(width: 28)
                                VStack(alignment: .leading, spacing: Layout.compact) {
                                    Text(period.title).foregroundStyle(Palette.ink)
                                    Text(period.dateLabel)
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                            }.frame(minHeight: Layout.touchTarget)
                        }.accessibilityIdentifier("suggested-period-\(period.title)")
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Dates & visits").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: start) { _, value in if end < value { end = value } }
            .task {
                range = model.mapPeriod != nil
                start = model.mapPeriod?.interval.start ?? model.selectedDay
                end = model.mapPeriod?.interval.end.addingTimeInterval(-1) ?? start
                do { periods = try await model.store?.suggestedPeriods() ?? [] }
                catch { loadError = true }
            }
    }
    private func apply() {
        if range { selectDays(from: start, through: end, title: "Selected period") }
        else { model.selectDay(start); dismiss() }
    }
    private func selectDays(from: Date, through: Date, title: String) {
        let lower = calendar.startOfDay(for: from)
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, through)))!
        model.selectPeriod(HistoryPeriod(title: title, interval: DateInterval(start: lower, end: upper)))
        dismiss()
    }
}


private extension HistoryPeriod {
    var dateLabel: String {
        let lastDay = interval.end.addingTimeInterval(-1)
        if Calendar.current.isDate(interval.start, inSameDayAs: lastDay) {
            return Calendar.current.isDateInToday(interval.start) ? "Today" : interval.start.formatted(date: .abbreviated, time: .omitted)
        }
        return interval.start.formatted(date: .abbreviated, time: .omitted) + " – " + lastDay.formatted(date: .abbreviated, time: .omitted)
    }
}
