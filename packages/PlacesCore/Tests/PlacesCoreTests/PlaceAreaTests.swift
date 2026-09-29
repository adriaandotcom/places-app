import Foundation
import Testing
@testable import PlacesCore

private func point(_ x: Double, _ y: Double) -> Coordinate { Coordinate(latitude: y, longitude: x) }
private let concave = [point(0, 0), point(0.02, 0), point(0.02, 0.005), point(0.005, 0.005), point(0.005, 0.02), point(0, 0.02)]

@Test func polygonsRespectConcaveEdgesHolesIslandsAndDateLine() {
    let area = PlaceArea(vertices: concave)
    #expect(area.isValid && PlaceArea.isSimple(concave))
    #expect(area.contains(point(0.003, 0.016)))
    #expect(!area.contains(point(0.01, 0.01)))
    #expect(area.distance(to: point(0.0051, 0.015)) > 10)
    let outer = [point(0, 0), point(1, 0), point(1, 1), point(0, 1)]
    let hole = [point(0.2, 0.2), point(0.8, 0.2), point(0.8, 0.8), point(0.2, 0.8)]
    let islands = PlaceArea(polygons: [.init(outer: outer, holes: [hole]), .init(outer: outer.map { point($0.longitude + 2, $0.latitude) })])
    #expect(islands.contains(point(0.1, 0.5)))
    #expect(!islands.contains(point(0.5, 0.5)))
    #expect(islands.contains(point(2.5, 0.5)))
    let dateline = PlaceArea(vertices: [point(179, 1), point(-179, 1), point(-179, 2), point(179, 2)])
    #expect(dateline.contains(point(180, 1.5)))
    #expect(!dateline.contains(point(0, 1.5)))
}

@Test func drawingsRejectCrossingsButAllowSeparatedCollinearEdges() {
    #expect(!PlaceArea.isSimple([point(0, 0), point(2, 2), point(0, 2), point(2, 0)]))
    #expect(!PlaceArea.isSimple([point(0, 0), point(1, 0), point(0, 0)]))
    #expect(PlaceArea.isSimple([point(0, 0), point(1, 0), point(1, 1), point(2, 1), point(2, 0), point(3, 0), point(3, 2), point(0, 2)]))
}

@Test func polygonRecognitionReplacesCircleWithoutInventingVisits() {
    let place = Place(name: "Fixture park", coordinate: point(0, 0), radius: 1_000, area: PlaceArea(vertices: concave))
    func fix(_ coordinate: Coordinate, accuracy: Double = 8) -> SensorObservation {
        SensorObservation(timestamp: Date(), source: .location, coordinate: coordinate, horizontalAccuracy: accuracy)
    }
    #expect(TrackingPolicy.matchingPlace(for: fix(point(0.003, 0.016)), places: [place])?.id == place.id)
    #expect(TrackingPolicy.matchingPlace(for: fix(point(0.006, 0.006)), places: [place]) == nil)
    #expect(TrackingPolicy.matchingPlace(for: fix(point(0.003, 0.016), accuracy: 500), places: [place]) == nil)
    #expect(place.contains(point(0.0051, 0.015), tolerance: 15))
    #expect(!place.contains(point(0.0051, 0.015), tolerance: 5))
}

@Test func savedAreasSurviveStorageAndRedactedReplayAndOlderPlacesStillDecode() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
    let store = try PlacesStore(path: path)
    let area = PlaceArea(polygons: [.init(outer: concave)], sourceName: "Fixture source")
    let place = Place(name: "Fixture private park", coordinate: point(0.003, 0.016), area: area)
    try await store.savePlace(place)
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.places().first?.area == area)
    let exported = try InferenceTestCase.decode(await store.exportTestCase())
    #expect(exported.input.places.first?.area?.polygons.first?.outer.count == concave.count)
    #expect(exported.input.places.first?.area?.sourceName == nil)
    #expect(exported.input.places.first?.area?.vertices != area.vertices)
    let old = Place(name: "Circle", coordinate: point(0, 0))
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    object.removeValue(forKey: "area")
    let decoded = try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.area == nil && decoded.contains(point(0, 0)))
}

@Test func compactParkCoordinatesDecodeWithoutLosingHoles() throws {
    let json = #"{"id":"fixture","name":"Fixture park","coordinate":{"latitude":0.1,"longitude":0.1},"area":{"sourceName":"OpenStreetMap","polygons":[{"outer":[[0,0],[1,0],[1,1],[0,1]],"holes":[[[0.2,0.2],[0.8,0.2],[0.8,0.8],[0.2,0.8]]]}]}}"#
    let park = try JSONDecoder().decode(MapPark.self, from: Data(json.utf8))
    #expect(park.area.contains(park.coordinate))
    #expect(!park.area.contains(point(0.5, 0.5)))
    #expect(park.area.isValid)
    #expect(try JSONDecoder().decode(MapPark.self, from: JSONEncoder().encode(park)) == park)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(MapPark.self, from: Data(json.replacingOccurrences(of: "[1,1]", with: "[1,1,2]").utf8))
    }
}

@Test func historicalCircleExitDoesNotEndAPolygonStay() {
    let coordinate = point(0.003, 0.016), time = Date(timeIntervalSince1970: 1_700_000_000)
    var place = Place(name: "Fixture park", coordinate: coordinate, area: PlaceArea(vertices: concave))
    let observations = [
        SensorObservation(timestamp: time, source: .location, coordinate: coordinate, horizontalAccuracy: 8),
        SensorObservation(timestamp: time.addingTimeInterval(10), source: .regionExit, monitoredPlaceID: place.id),
        SensorObservation(timestamp: time.addingTimeInterval(20), source: .location, coordinate: coordinate, horizontalAccuracy: 8)
    ]
    let areaTimeline = InferenceEngine.infer(observations: observations, places: [place])
    #expect(areaTimeline.count == 1 && areaTimeline.first?.kind == .stay)
    place.area = nil
    let circleTimeline = InferenceEngine.infer(observations: observations, places: [place])
    #expect(circleTimeline.contains { $0.kind == .journey })
}
