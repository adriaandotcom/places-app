#if DEBUG
import Foundation
import PlacesCore

enum DemoFixtures {
    static func seedUnnamedStay(_ store: PlacesStore, withSavedPlace: Bool) async throws {
        if withSavedPlace {
            try await store.savePlace(Place(name: "Fixture Existing", coordinate: Coordinate(latitude: 0, longitude: 0.02)))
        }
        let start = Date().addingTimeInterval(-600)
        let coordinate = Coordinate(latitude: 0, longitude: 0)
        try await store.append([
            SensorObservation(timestamp: start, source: .visitArrival, coordinate: coordinate, horizontalAccuracy: 10),
            SensorObservation(timestamp: start.addingTimeInterval(300), source: .location, coordinate: coordinate, horizontalAccuracy: 10)
        ])
    }

    static func seed(_ store: PlacesStore) async throws {
        let start = Calendar.current.startOfDay(for: Date())
        let home = Place(id: "demo-home", name: "Home", coordinate: Coordinate(latitude: 52.37, longitude: 4.85), symbol: "house.fill", colorIndex: 0)
        let studio = Place(id: "demo-studio", name: "The studio", coordinate: Coordinate(latitude: 52.375, longitude: 4.875), symbol: "briefcase.fill", colorIndex: 1)
        let cafe = Place(id: "demo-cafe", name: "A little coffee stop", coordinate: Coordinate(latitude: 52.373, longitude: 4.866), symbol: "cup.and.saucer.fill", colorIndex: 2)
        for place in [home, studio, cafe] { try await store.savePlace(place) }
        let now = Date()
        let available = now.timeIntervalSince(start)
        let scale = min(1, available / (19 * 3600))
        func sample(_ hours: Double, _ coordinate: Coordinate, speed: Double = 0, motion: MotionKind = .stationary) -> SensorObservation {
            SensorObservation(timestamp: start.addingTimeInterval(hours * 3600 * scale), source: .location,
                        coordinate: coordinate, horizontalAccuracy: 12, speed: speed, motion: motion)
        }
        var values = [sample(0, home.coordinate), sample(8.7, home.coordinate)]
        for step in 1...12 {
            let ratio = Double(step) / 13
            values.append(sample(8.7 + ratio * 0.3, Coordinate(latitude: 52.37 + 0.005 * ratio, longitude: 4.85 + 0.025 * ratio), speed: 4, motion: .cycling))
        }
        values += [sample(9, studio.coordinate), sample(12.3, studio.coordinate)]
        for step in 1...6 {
            let ratio = Double(step) / 7
            values.append(sample(12.3 + ratio * 0.15, Coordinate(latitude: 52.375 - 0.002 * ratio, longitude: 4.875 - 0.009 * ratio), speed: 1.5, motion: .walking))
        }
        values += [sample(12.45, cafe.coordinate), sample(13.25, cafe.coordinate),
                   SensorObservation(timestamp: start.addingTimeInterval(14 * 3600 * scale), source: .recovery), sample(14.1, studio.coordinate)]
        try await store.append(values)
    }
}
#endif
