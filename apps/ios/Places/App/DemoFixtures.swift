#if DEBUG
import Foundation
import UIKit
import PlacesCore

enum DemoFixtures {
    static func seedRewind(_ store: PlacesStore) async throws {
        let calendar = Calendar.current
        let current = calendar.dateInterval(of: .month, for: Date())!.start
        let start = calendar.date(byAdding: .month, value: -1, to: current)!
        let home = Place(id: "rewind-home", name: "Little home", coordinate: Coordinate(latitude: 1, longitude: 1), symbol: "house.fill")
        let cafe = Place(id: "rewind-cafe", name: "Corner café", coordinate: Coordinate(latitude: 1.1, longitude: 1.1), symbol: "cup.and.saucer.fill", colorIndex: 2,
                         locality: PlaceLocality(city: "Amsterdam", country: "Netherlands"))
        try await store.savePlace(home); try await store.savePlace(cafe)
        var evidence: [SensorObservation] = []
        for day in 1...4 {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            let coordinate = day == 4 ? Coordinate(latitude: 2, longitude: 2) : (day == 1 ? home.coordinate : cafe.coordinate)
            evidence.append(SensorObservation(timestamp: date.addingTimeInterval(10 * 3600), source: .visitArrival, coordinate: coordinate, horizontalAccuracy: 10))
            evidence.append(SensorObservation(timestamp: date.addingTimeInterval(12 * 3600), source: .visitDeparture, coordinate: coordinate, horizontalAccuracy: 10))
        }
        try await store.append(evidence)
        try await store.correct(UserOverride(start: start.addingTimeInterval(86400 + 12 * 3600), end: start.addingTimeInterval(86400 + 13 * 3600), kind: .journey, mode: .walking))
        let friend = MemoryPerson(id: "rewind-friend", name: "Alex", colorIndex: 4)
        try await store.savePerson(friend)
        try await store.saveTrip(Trip(id: "rewind-trip", title: "A city break", start: start.addingTimeInterval(86400), end: start.addingTimeInterval(4 * 86400), personIDs: [friend.id]))
        try await store.saveMemory(PlaceMemory(text: "A slow morning, good coffee, and nowhere to rush.", date: start.addingTimeInterval(2 * 86400), tripID: "rewind-trip", personIDs: [friend.id]))
    }

    @MainActor static func seedPhotoBrowser(_ store: PlacesStore) async throws {
        try await seedMemories(store)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-2 * 86400)
        let trip = Trip(id: "photo-trip", title: "Island week", start: start, personIDs: ["memory-friend"])
        try await store.saveTrip(trip)
        var photos: [MemoryPhoto] = []
        for index in 0..<9 {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600), format: format).image { context in
                UIColor(hue: CGFloat(index) / 10, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                ("Photo \(index + 1)" as NSString).draw(at: CGPoint(x: 60, y: 250), withAttributes: [.font: UIFont.systemFont(ofSize: 80), .foregroundColor: UIColor.white])
            }
            var photo = try MemoryPhotoImport.make(image.jpegData(compressionQuality: 0.8)!)
            photo.details = MemoryPhotoDetails(createdAt: start.addingTimeInterval(Double(index + 1) * 3600), utcOffsetSeconds: 7200,
                coordinate: index == 0 ? Coordinate(latitude: 52.37, longitude: 4.9) : nil)
            photos.append(photo)
        }
        try await store.saveMemory(PlaceMemory(text: "A week of small moments together.", tripID: trip.id, personIDs: trip.personIDs, photoIDs: photos.reversed().map(\.id)), adding: photos)
    }
    static func seedMemories(_ store: PlacesStore) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -2, to: today)!
        let home = Place(id: "memory-home", name: "Fixture Home", coordinate: Coordinate(latitude: 52.36, longitude: 4.9), symbol: "house.fill")
        let hotel = Place(id: "memory-hotel", name: "Seaside stay", coordinate: Coordinate(latitude: 36.87, longitude: 27.18), symbol: "bed.double.fill", colorIndex: 2,
                          locality: PlaceLocality(city: "Kos", country: "Greece"))
        try await store.savePlace(home); try await store.savePlace(hotel)
        try await store.append([SensorObservation(timestamp: start, source: .location, coordinate: home.coordinate, horizontalAccuracy: 10)])
        try await store.correct(UserOverride(start: start, end: start.addingTimeInterval(8 * 3600), kind: .stay, placeID: home.id))
        try await store.correct(UserOverride(start: start.addingTimeInterval(18 * 3600), end: today, kind: .stay, placeID: hotel.id))
        let person = MemoryPerson(id: "memory-friend", name: "Alex")
        try await store.savePerson(person)
        let memory = PlaceMemory(text: "Breakfast by the sea", date: start.addingTimeInterval(30 * 3600), placeID: hotel.id, visitStart: start.addingTimeInterval(30 * 3600), personIDs: [person.id])
        try await store.saveMemory(memory)
    }

    static func seedMapPeriods(_ store: PlacesStore) async throws {
        let start = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
        let places = [
            Place(id: "map-amsterdam-west", name: "Fixture Amsterdam West", coordinate: Coordinate(latitude: 52.37, longitude: 4.85)),
            Place(id: "map-amsterdam-east", name: "Fixture Amsterdam East", coordinate: Coordinate(latitude: 52.37, longitude: 4.90)),
            Place(id: "map-kos-west", name: "Fixture Kos West", coordinate: Coordinate(latitude: 36.81, longitude: 27.09)),
            Place(id: "map-kos-east", name: "Fixture Kos East", coordinate: Coordinate(latitude: 36.89, longitude: 27.28))
        ]
        for (index, var place) in places.enumerated() {
            place.locality = PlaceLocality(city: index < 2 ? "Amsterdam" : "Kos", country: index < 2 ? "Netherlands" : "Greece")
            try await store.savePlace(place)
        }
        var observations: [SensorObservation] = []
        for (index, offset) in [0.0, 900, 86_400, 87_300].enumerated() {
            for (seconds, source) in [(offset, ObservationSource.visitArrival), (offset + 600, .visitDeparture)] {
                observations.append(SensorObservation(timestamp: start.addingTimeInterval(seconds), source: source,
                    coordinate: places[index].coordinate, horizontalAccuracy: 10))
            }
        }
        for (offset, first, last) in [(600.0, places[0], places[1]), (87_000.0, places[2], places[3])] {
            for step in 1...4 {
                let fraction = Double(step) / 5
                observations.append(SensorObservation(timestamp: start.addingTimeInterval(offset + fraction * 300), source: .location,
                    coordinate: Coordinate(latitude: first.coordinate.latitude + (last.coordinate.latitude - first.coordinate.latitude) * fraction,
                        longitude: first.coordinate.longitude + (last.coordinate.longitude - first.coordinate.longitude) * fraction),
                    horizontalAccuracy: 10, speed: 8, motion: .automotive))
            }
        }
        try await store.append(observations.sorted { $0.timestamp < $1.timestamp })
        for (index, offset) in [0.0, 900, 86_400, 87_300].enumerated() {
            try await store.correct(UserOverride(start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 600),
                kind: .stay, placeID: places[index].id))
        }
        for (from, to, mode) in [(600.0, 900.0, TransportMode.driving), (1500, 86_400, .plane), (87_000, 87_300, .driving)] {
            try await store.correct(UserOverride(start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), kind: .journey, mode: mode))
        }
    }

    static func seedNearbyWiFi(_ store: PlacesStore) async throws {
        let coordinate = Coordinate(latitude: 1, longitude: 1)
        try await store.savePlace(Place(name: "Fixture Hotel", coordinate: coordinate, expectedSSIDs: ["Already added"]))
        let values = [("Fixture Guest", coordinate), ("Fixture Guest", coordinate),
                      ("Fixture Garden", Coordinate(latitude: 1.01, longitude: 1)),
                      ("Other city", Coordinate(latitude: 2, longitude: 2)), ("Already added", coordinate)]
        try await store.append(values.enumerated().map { index, value in
            SensorObservation(timestamp: Date().addingTimeInterval(Double(index - 10) * 60), source: .wifi,
                coordinate: value.1, horizontalAccuracy: 10, ssid: value.0,
                bssid: String(format: "02:00:00:00:00:%02x", index))
        })
    }

    static func seedGapSuggestions(_ store: PlacesStore) async throws -> Date {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday)!
        let home = Place(id: "gap-home", name: "Home", coordinate: Coordinate(latitude: 1, longitude: 1), symbol: "house.fill")
        try await store.savePlace(home)
        try await store.append([SensorObservation(timestamp: start, source: .visitArrival, coordinate: home.coordinate, horizontalAccuracy: 10),
            SensorObservation(timestamp: start.addingTimeInterval(1100), source: .location, coordinate: home.coordinate, horizontalAccuracy: 10)])
        try await store.correct(UserOverride(start: start.addingTimeInterval(300), end: start.addingTimeInterval(600), kind: .gap))
        return calendar.startOfDay(for: start)
    }

    static func seedHistoryNavigation(_ store: PlacesStore) async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let home = Place(id: "calendar-home", name: "Home", coordinate: Coordinate(latitude: 1, longitude: 1), symbol: "house.fill")
        try await store.savePlace(home)
        for daysAgo in [90, 60, 30, 3, 0] {
            let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!
            try await store.append([
                SensorObservation(timestamp: start, source: .visitArrival, coordinate: home.coordinate, horizontalAccuracy: 10),
                SensorObservation(timestamp: start.addingTimeInterval(120), source: .visitDeparture, coordinate: home.coordinate, horizontalAccuracy: 10)
            ])
        }
    }

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

    static func seedUnnamedStay(_ store: PlacesStore, withSavedPlace: Bool,
                                coordinate: Coordinate = Coordinate(latitude: 0, longitude: 0)) async throws {
        if withSavedPlace {
            try await store.savePlace(Place(name: "Fixture Existing", coordinate: Coordinate(latitude: 0, longitude: 0.02)))
        }
        let start = Date().addingTimeInterval(-600)
        try await store.append([
            SensorObservation(timestamp: start, source: .visitArrival, coordinate: coordinate, horizontalAccuracy: 10),
            SensorObservation(timestamp: start.addingTimeInterval(300), source: .location, coordinate: coordinate, horizontalAccuracy: 10)
        ])
    }

    static func seed(_ store: PlacesStore, now: Date = Date()) async throws {
        let start = Calendar.current.startOfDay(for: now)
        let home = Place(id: "demo-home", name: "Home", coordinate: Coordinate(latitude: 52.37, longitude: 4.85), symbol: "house.fill", colorIndex: 0)
        let studio = Place(id: "demo-studio", name: "The studio", coordinate: Coordinate(latitude: 52.375, longitude: 4.875), symbol: "briefcase.fill", colorIndex: 1)
        let cafe = Place(id: "demo-cafe", name: "A little coffee stop", coordinate: Coordinate(latitude: 52.373, longitude: 4.866), symbol: "cup.and.saucer.fill", colorIndex: 2)
        for var place in [home, studio, cafe] {
            place.locality = PlaceLocality(city: "Amsterdam", country: "Netherlands")
            try await store.savePlace(place)
        }
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
