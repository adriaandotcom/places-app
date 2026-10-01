import SwiftUI

struct ExportPeriodSelection {
    enum Choice: String, CaseIterable, Identifiable {
        case all, week, month, days, dates
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "All history"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .days: "Number of days"
            case .dates: "Choose dates"
            }
        }
    }
    var choice = Choice.all
    var days = 7
    var start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    var end = Date()

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        guard choice != .all else { return nil }
        let today = calendar.startOfDay(for: now)
        let first: Date, last: Date
        if choice == .dates {
            first = calendar.startOfDay(for: min(start, end))
            last = calendar.startOfDay(for: max(start, end))
        } else {
            let count = choice == .week ? 7 : choice == .month ? 30 : min(3650, max(1, days))
            first = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
            last = today
        }
        return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? now)
    }
}

/// One period control for history, GPX, test cases and full support reports.
struct ExportPeriodPicker: View {
    @Binding var selection: ExportPeriodSelection
    var body: some View {
        Picker("Period", selection: $selection.choice) {
            ForEach(ExportPeriodSelection.Choice.allCases) { choice in Text(choice.title).tag(choice) }
        }.accessibilityIdentifier("export-period")
        if selection.choice == .days {
            LabeledContent("Days") {
                TextField("Days", value: $selection.days, format: .number.grouping(.never))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(maxWidth: Layout.iconTile).accessibilityIdentifier("export-days")
            }
        } else if selection.choice == .dates {
            DatePicker("From", selection: $selection.start, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("export-from")
            DatePicker("Through", selection: $selection.end, in: selection.start...max(selection.start, Date()), displayedComponents: .date)
                .accessibilityIdentifier("export-through")
        }
    }
}
