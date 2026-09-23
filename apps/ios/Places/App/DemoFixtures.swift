#if DEBUG
import Foundation
import PlacesCore

enum DemoFixtures {
    static func seedWiFiRecovery(_ store: PlacesStore) async throws {
        let start = Calendar.current.startOfDay(for: Date())
        let home = Place(id: "recovery-home", name: "Home", coordinate: .init(latitude: 1, longitude: 1), symbol: "house.fill")
        try await store.savePlace(home)
        func wifi(_ seconds: Double, learnsLocation: Bool = false) -> SensorObservation {
            SensorObservation(timestamp: start.addingTimeInterval(seconds), source: .wifi,
                coordinate: learnsLocation ? home.coordinate : nil, horizontalAccuracy: learnsLocation ? 10 : nil,
                ssid: "Fixture Wi-Fi", bssid: "02:00:00:00:00:01")
        }
        try await store.append([wifi(-600, learnsLocation: true), wifi(42),
            SensorObservation(timestamp: start.addingTimeInterval(1314), source: .recovery), wifi(1315)])
    }

    static func seedGroupedHistory(_ store: PlacesStore) async throws {
        let start = Calendar.current.startOfDay(for: Date())
        let home = Place(id: "group-home", name: "Home", coordinate: Coordinate(latitude: 1, longitude: 1), symbol: "house.fill")
        try await store.savePlace(home)
        func fix(_ seconds: Double, coordinate: Coordinate = home.coordinate) -> SensorObservation {
            SensorObservation(id: "group-fix-\(seconds)", timestamp: start.addingTimeInterval(seconds), source: .location,
                              coordinate: coordinate, horizontalAccuracy: 10)
        }
        try await store.append([
            fix(0, coordinate: Coordinate(latitude: 1, longitude: 1.01)), fix(1800), fix(2000),
            SensorObservation(timestamp: start.addingTimeInterval(2001), source: .recovery), fix(2010), fix(2100)
        ])
        try await store.correct(UserOverride(start: start.addingTimeInterval(2000), end: start.addingTimeInterval(2010),
                                            kind: .stay, placeID: home.id))
    }

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
