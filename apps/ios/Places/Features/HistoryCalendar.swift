import SwiftUI
import UIKit
import PlacesCore

struct HistoryCalendar: UIViewRepresentable {
    let days: [HistoryDay]
    @Binding var selection: Date
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = .current
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.accessibilityIdentifier = "history-calendar"
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        let oldDays = context.coordinator.parent.days
        context.coordinator.parent = self
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = min(days.first?.date ?? today, calendar.startOfDay(for: selection))
        view.availableDateRange = DateInterval(start: earliest, end: calendar.date(byAdding: .day, value: 1, to: today)!.addingTimeInterval(-1))
        let components = calendar.dateComponents([.year, .month, .day], from: selection)
        let behavior = view.selectionBehavior as? UICalendarSelectionSingleDate
        if behavior?.selectedDate != components {
            behavior?.setSelected(components, animated: false)
            view.setVisibleDateComponents(components, animated: false)
        }
        if oldDays != days {
            view.reloadDecorations(forDateComponents: Set(oldDays.map(\.date) + days.map(\.date)).map {
                calendar.dateComponents([.year, .month, .day], from: $0)
            }, animated: false)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: max(340, size.height))
    }
    @MainActor final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: HistoryCalendar
        init(_ parent: HistoryCalendar) { self.parent = parent }
        private func entry(_ components: DateComponents?) -> HistoryDay? {
            guard let components, let date = Calendar.current.date(from: components) else { return nil }
            return parent.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            entry(dateComponents) != nil
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            if let day = entry(dateComponents) { parent.selection = day.date }
        }
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let day = entry(dateComponents), day.placeCount > 0 else { return nil }
            return .customView {
                let dots = UILabel()
                dots.text = Array(repeating: "•", count: min(3, day.placeCount)).joined(separator: " ")
                dots.font = .systemFont(ofSize: 11, weight: .bold)
                dots.textColor = .secondaryLabel
                dots.sizeToFit()
                dots.isAccessibilityElement = true
                dots.accessibilityLabel = "\(day.placeCount) \(day.placeCount == 1 ? "place" : "places")"
                return dots
            }
        }
    }
}

struct TimelineDayStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var position = ScrollPosition(x: 0)
    @State private var scrollOffset: CGFloat = 0
    let progress: CGFloat
    private let calendar = Calendar.current
    private var cellHeight: CGFloat { typeSize.isAccessibilitySize ? 104 : 72 }
    private let cellRadius: CGFloat = 18
    private let spacing: CGFloat = 7
    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        var day = min(model.historyDays.first?.date ?? today, calendar.date(byAdding: .day, value: -6, to: today)!, calendar.startOfDay(for: model.selectedDay))
        var result: [Date] = []
        while day <= today {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(typeSize.isAccessibilitySize ? 72 : 48, (geometry.size.width - 6 * spacing) / 7)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(days, id: \.self) { day in
                        let entry = model.historyDays.first { $0.date == day }
                        let selected = calendar.isDate(day, inSameDayAs: model.selectedDay)
                        let distance = CGFloat(calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: model.selectedDay)).day ?? 0)
                        let x = (distance + (reduceMotion ? 0 : progress)) * (width + spacing)
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { model.selectDay(day) }
                        } label: {
                            dayLabel(day, count: entry?.placeCount ?? 0)
                                .foregroundStyle(entry == nil ? Palette.muted.opacity(0.55) : Palette.ink)
                                .frame(width: width, height: cellHeight)
                                .background(Palette.paper)
                                .overlay {
                                    GeometryReader { _ in
                                        RoundedRectangle(cornerRadius: cellRadius).fill(Palette.ink).offset(x: x)
                                        dayLabel(day, count: entry?.placeCount ?? 0).foregroundStyle(Palette.background)
                                            .frame(width: width, height: cellHeight)
                                            .mask { RoundedRectangle(cornerRadius: cellRadius).offset(x: x) }
                                    }.allowsHitTesting(false).accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                                .clipShape(RoundedRectangle(cornerRadius: cellRadius))
                        }.buttonStyle(.plain).id(day)
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                            .accessibilityValue(entry.map { "\($0.placeCount) \($0.placeCount == 1 ? "place" : "places")" } ?? "No history")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("timeline-day-\(calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: day).day ?? 0)")
                    }
                }.scrollTargetLayout()
            }.scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in scrollOffset = offset }
                .accessibilityIdentifier("timeline-days")
                .accessibilityLabel("Timeline date")
                .accessibilityValue(model.selectedDay.formatted(date: .complete, time: .omitted))
                .accessibilityAdjustableAction { direction in model.shiftDay(direction == .increment ? 1 : -1) }
                .onAppear { position.scrollTo(id: calendar.startOfDay(for: model.selectedDay), anchor: .center) }
                .onChange(of: model.selectedDay) { _, _ in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        revealSelection(width: width, viewportWidth: geometry.size.width, progress: 0, settled: true)
                    }
                }
                .onChange(of: progress) { _, value in
                    if !reduceMotion, value != 0 { revealSelection(width: width, viewportWidth: geometry.size.width, progress: value) }
                }
        }.frame(height: cellHeight)
    }
    private func revealSelection(width: CGFloat, viewportWidth: CGFloat, progress: CGFloat, settled: Bool = false) {
        guard let index = days.firstIndex(of: calendar.startOfDay(for: model.selectedDay)) else { return }
        let left = (CGFloat(index) + progress) * (width + spacing)
        if settled {
            // Resolve the actual lazy-cell bounds at rest instead of relying on
            // estimated content positions, which can include an inter-cell gap.
            if left <= scrollOffset + spacing { position.scrollTo(id: days[index], anchor: .leading) }
            else if left + width >= scrollOffset + viewportWidth - spacing { position.scrollTo(id: days[index], anchor: .trailing) }
            return
        }
        let maximum = max(0, CGFloat(days.count) * (width + spacing) - spacing - viewportWidth)
        // Follow the moving highlight only at an edge. Ordinary horizontal browsing
        // keeps its native momentum and visible dates stay still during a day swipe.
        let target = min(maximum, max(0, min(left - spacing, max(scrollOffset, left + width + spacing - viewportWidth))))
        if abs(target - scrollOffset) > 0.5 { position.scrollTo(x: target) }
    }
    private func dayLabel(_ day: Date, count: Int) -> some View {
        VStack(spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
            Text(day.formatted(.dateTime.day())).font(BrandFont.title)
            HStack(spacing: 3) { ForEach(0..<min(3, count), id: \.self) { _ in Circle().frame(width: 4, height: 4) } }
                .frame(height: 4).accessibilityHidden(true)
        }
    }
}
