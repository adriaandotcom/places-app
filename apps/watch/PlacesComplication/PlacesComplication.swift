import CoreLocation
import SwiftUI
import WidgetKit

struct PlacesEntry: TimelineEntry {
    let date: Date
    let recorded: Date?
    let enabled: Bool
}

struct PlacesProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlacesEntry { PlacesEntry(date: Date(), recorded: nil, enabled: false) }
    func getSnapshot(in context: Context, completion: @escaping (PlacesEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PlacesEntry>) -> Void) {
        let preview = context.isPreview
        Task { @MainActor in
            if !preview, WatchStorage.enabled {
                let request = WatchLocationSnapshot()
                if let fix = await request.capture() {
                    // Failure leaves the last successful observation visible; never claim a fresh fix.
                    try? await WatchStorage.record(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                        accuracy: fix.horizontalAccuracy, speed: fix.speed >= 0 ? fix.speed : nil, date: fix.timestamp)
                }
            }
            let entry = PlacesEntry(date: Date(), recorded: WatchStorage.lastRecorded, enabled: WatchStorage.enabled)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1_800))))
        }
    }
}

@main struct PlacesComplication: Widget {
    let kind = "PlacesCompanion"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlacesProvider()) { entry in
            HStack(spacing: 6) {
                PlacesMarker().fill(.primary, style: FillStyle(eoFill: true)).frame(width: 18, height: 25)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Places").font(.headline)
                    if let date = entry.recorded { Text(date, style: .time).font(.caption2) }
                    else { Text(entry.enabled ? "Waiting" : "Paused").font(.caption2) }
                }
            }.containerBackground(.fill.tertiary, for: .widget)
                .accessibilityLabel(entry.recorded.map { "Places. Last recorded \($0.formatted())" } ?? "Places. No location recorded yet.")
        }
        .configurationDisplayName("Places")
        .description("Your last recorded location time. Helps Places collect automatically when watchOS allows.")
        .supportedFamilies([.accessoryRectangular])
    }
}
