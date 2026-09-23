import Foundation
import Testing
@testable import PlacesCore

private let tripStart = Date(timeIntervalSince1970: 1_735_689_600)
private func trip(duration: Double = 600) -> TimelineItem {
    TimelineItem(id: "fixture-trip", kind: .journey, start: tripStart,
                 end: tripStart.addingTimeInterval(duration), lastEvidenceAt: tripStart.addingTimeInterval(duration))
}
private func samples(speed: Double, duration: Double = 600) -> [SensorObservation] {
    stride(from: 0.0, through: duration, by: 60).map { seconds in
        let longitude = (speed / 3.6 * seconds) / 6_371_000 * 180 / Double.pi
        return SensorObservation(timestamp: tripStart.addingTimeInterval(seconds), source: .location,
            coordinate: Coordinate(latitude: 0, longitude: longitude), horizontalAccuracy: 5, speed: speed / 3.6)
    }
}

@Test(arguments: [(5.0, TransportMode.walking), (18.0, .cycling), (70.0, .driving), (200.0, .train), (720.0, .plane)])
func transportChoicesRankByRecordedDistanceAndTime(speed: Double, first: TransportMode) {
    let result = TransportSuggestions.make(for: trip(), observations: samples(speed: speed))
    #expect(result.suggested.first == first)
    #expect(abs((result.estimatedSpeedKilometersPerHour ?? 0) - speed) < 0.1)
    #expect(Set(result.suggested + result.otherModes) == Set(TransportMode.allCases))
    #expect((result.suggested + result.otherModes).count == TransportMode.allCases.count)
    #expect(result.otherModes.contains(.ferry))
}

@Test func motionRefinesRankingOnlyWhenSpeedAgrees() {
    let motion = SensorObservation(timestamp: tripStart.addingTimeInterval(590), source: .motion, motion: .automotive)
    #expect(TransportSuggestions.make(for: trip(), observations: samples(speed: 18) + [motion]).suggested.first == .driving)
    #expect(TransportSuggestions.make(for: trip(), observations: samples(speed: 720) + [motion]).suggested.first == .plane)
}

@Test func shortEmptyAndSparseIntervalsStayNeutral() {
    #expect(TransportSuggestions.make(for: trip(duration: 0), observations: samples(speed: 720)) == .none)
    #expect(TransportSuggestions.make(for: trip(duration: 30), observations: samples(speed: 720)) == .none)
    #expect(TransportSuggestions.make(for: trip(), observations: []) == .none)
    let values = samples(speed: 720)
    #expect(TransportSuggestions.make(for: trip(), observations: [values.first!, values.last!]) == .none)
    #expect(TransportSuggestions.make(for: trip(), observations: Array(values.prefix(3))) == .none)
    #expect(TransportSuggestions.make(for: trip(duration: 120), observations: samples(speed: 720, duration: 120)) == .none)
}

@Test func stationaryJitterAndGPSJumpDoNotSuggestTravelModes() {
    var jitter = samples(speed: 0)
    for i in jitter.indices { jitter[i].coordinate?.longitude = i.isMultiple(of: 2) ? 0.0001 : -0.0001 }
    #expect(TransportSuggestions.make(for: trip(), observations: jitter) == .none)
    var jump = samples(speed: 5)
    jump[5].coordinate = Coordinate(latitude: 0, longitude: 0.08)
    #expect(TransportSuggestions.make(for: trip(), observations: jump) == .none)
}

@Test func speedEstimationDoesNotBridgeMissingOrUnavailableEvidence() {
    let values = samples(speed: 70)
    let recovery = SensorObservation(timestamp: tripStart.addingTimeInterval(310), source: .recovery)
    #expect(TransportSuggestions.make(for: trip(), observations: values + [recovery]) == .none)
    #expect(TransportSuggestions.make(for: trip(), observations: [values[0], values[1], values[8], values[9], values[10]]) == .none)
    var coarse = values
    for i in coarse.indices { coarse[i].horizontalAccuracy = 200 }
    #expect(TransportSuggestions.make(for: trip(), observations: coarse) == .none)
    var stale = values
    for i in stale.indices { stale[i].coordinateTimestamp = tripStart.addingTimeInterval(-200) }
    #expect(TransportSuggestions.make(for: trip(), observations: stale) == .none)
    var wifi = values
    for i in wifi.indices { wifi[i].source = .wifi }
    #expect(TransportSuggestions.make(for: trip(), observations: wifi) == .none)
}

@Test func duplicateCallbacksAndUnrelatedSamplesDoNotDistortSpeed() {
    let values = samples(speed: 18)
    var unrelated = samples(speed: 720)
    for i in unrelated.indices { unrelated[i].timestamp = unrelated[i].timestamp.addingTimeInterval(3600) }
    let result = TransportSuggestions.make(for: trip(), observations: (values + values + unrelated).reversed())
    #expect(result.suggested.first == .cycling)
    #expect(abs((result.estimatedSpeedKilometersPerHour ?? 0) - 18) < 0.1)
}

@Test func existingModesRemainCompatibleWithSavedHistory() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(TransportMode.self, from: Data("\"train\"".utf8)).title == "Public transport")
    #expect(try decoder.decode(TransportMode.self, from: Data("\"driving\"".utf8)).title == "Car")
    for mode in TransportMode.allCases {
        #expect(try decoder.decode(TransportMode.self, from: JSONEncoder().encode(mode)) == mode)
    }
}

@Test(arguments: [TransportMode.plane, .ferry])
func newTransportCorrectionsPersistAndOutrankSuggestions(mode: TransportMode) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let store = try PlacesStore(path: path)
    try await store.append(samples(speed: 18))
    let interval = trip()
    #expect(try await store.transportSuggestions(for: interval).suggested.first == .cycling)
    try await store.correct(UserOverride(start: interval.start, end: interval.end!, kind: .journey, mode: mode))
    let reopened = try PlacesStore(path: path)
    let items = try await reopened.timeline(on: tripStart)
    #expect(items.filter(\.isUserEdited).allSatisfy { $0.mode == mode })
    #expect(items.contains { $0.isUserEdited && $0.mode == mode })
    #expect(try await reopened.observations().count == 11)
}
