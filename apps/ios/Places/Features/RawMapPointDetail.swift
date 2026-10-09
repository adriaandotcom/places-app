import SwiftUI
import PlacesCore

struct RawMapPointDetail: View {
    @Environment(\.dismiss) private var dismiss
    let points: [RawMapPoint]
    let initialID: String
    @State private var selectedID: String?
    private var index: Int { points.firstIndex { $0.id == (selectedID ?? initialID) } ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                if points.indices.contains(index) {
                    let point = points[index]
                    Section {
                        HStack {
                            Button { selectedID = points[index - 1].id } label: {
                                Image(systemName: "chevron.left").frame(width: Layout.touchTarget, height: Layout.touchTarget)
                            }.disabled(index == 0).accessibilityLabel("Previous raw point")
                            Spacer()
                            Text("Point \(index + 1) of \(points.count)").font(.headline).monospacedDigit()
                                .accessibilityIdentifier("raw-point-position")
                            Spacer()
                            Button { selectedID = points[index + 1].id } label: {
                                Image(systemName: "chevron.right").frame(width: Layout.touchTarget, height: Layout.touchTarget)
                            }.disabled(index == points.count - 1).accessibilityLabel("Next raw point")
                        }.buttonStyle(.borderless)
                        LabeledContent("Recorded", value: point.timestamp.formatted(date: .abbreviated, time: .standard))
                            .accessibilityIdentifier("raw-point-time")
                        if let measured = point.measuredAt, measured != point.timestamp {
                            LabeledContent("Location measured", value: measured.formatted(date: .abbreviated, time: .standard))
                        }
                        LabeledContent("Time zone", value: TimeZone.current.identifier)
                        LabeledContent("Latitude", value: String(format: "%.6f", point.coordinate.latitude))
                        LabeledContent("Longitude", value: String(format: "%.6f", point.coordinate.longitude))
                        LabeledContent("Collector", value: point.collector)
                        LabeledContent("Source", value: point.source)
                        LabeledContent {
                            Label(point.device, systemImage: "circle.fill").foregroundStyle(Palette.accent(point.colorIndex))
                        } label: { Text("From") }
                        LabeledContent("Accuracy", value: point.accuracy.flatMap { $0.isFinite && $0 >= 0 ? "±\($0.formatted(.number.precision(.fractionLength(0)))) m" : nil } ?? "Not recorded")
                        if let speed = point.speed, speed.isFinite, speed >= 0 {
                            LabeledContent("Speed", value: "\(speed.formatted(.number.precision(.fractionLength(1)))) m/s")
                        }
                    } footer: {
                        Text("Dashed lines connect observations in time order, including gaps. They do not show a recorded route. Raw points can include cached or inaccurate locations.")
                    }
                }
            }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .navigationTitle("Raw point").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.controlGreen)
    }
}
