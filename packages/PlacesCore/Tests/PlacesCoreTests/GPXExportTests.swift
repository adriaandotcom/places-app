import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import PlacesCore

private let gpxDate = Date(timeIntervalSince1970: 1_700_000_000.125)
private let gpxCoordinate = Coordinate(latitude: 52.37, longitude: 4.89)

private func fix(_ seconds: Double, source: ObservationSource = .location,
                 coordinate: Coordinate = gpxCoordinate, accuracy: Double = 10) -> SensorObservation {
    SensorObservation(timestamp: gpxDate.addingTimeInterval(seconds), source: source,
                      coordinate: coordinate, horizontalAccuracy: accuracy)
}

@Test func gpxNeverConnectsDifferentPhysicalDevices() throws {
    var watch = fix(30); watch.companionDevice = .watch; watch.companionDeviceID = "watch-one"
    var mac = fix(60); mac.companionDevice = .mac; mac.companionDeviceID = "mac-one"
    var otherMac = fix(90); otherMac.companionDevice = .mac; otherMac.companionDeviceID = "mac-two"
    let xml = try XMLDocument(data: GPXExport.encode(places: [], observations: [fix(0), watch, mac, otherMac]))
    #expect(try xml.nodes(forXPath: "//trkseg").count == 4)
    #expect(try xml.nodes(forXPath: "//trkpt").count == 4)
}

@Test func gpxPreservesCoordinatesAndTimesWithoutPrivateExtras() async throws {
    let store = try PlacesStore(path: ":memory:")
    let name = "Café & <Park> \"West\" 🏞"
    try await store.savePlace(Place(name: name, address: "Excluded address", coordinate: gpxCoordinate, expectedSSIDs: ["Excluded WiFi"]))
    var sample = fix(0)
    sample.ssid = "Excluded WiFi"; sample.bssid = "02:00:00:00:00:99"
    try await store.append([sample, fix(60, source: .significantChange), fix(70, source: .wifi)])
    let data = try await store.exportGPX()
    let xml = try XMLDocument(data: data)
    #expect(xml.rootElement()?.uri == "http://www.topografix.com/GPX/1/1")
    #expect(xml.rootElement()?.attribute(forName: "version")?.stringValue == "1.1")
    #expect(try xml.nodes(forXPath: "//wpt/name").first?.stringValue == name)
    #expect(try xml.nodes(forXPath: "//trkpt").count == 2)
    #expect(try xml.nodes(forXPath: "//trkpt/@lat").first?.stringValue == "52.37000000")
    #expect(try xml.nodes(forXPath: "//trkpt/@lon").first?.stringValue == "4.89000000")
    #expect(try xml.nodes(forXPath: "//trkpt/time").first?.stringValue == "2023-11-14T22:13:20.125Z")
    let text = String(decoding: data, as: UTF8.self)
    for excluded in ["Excluded", "02:00:", "ssid", "bssid", "person", "photo"] { #expect(!text.contains(excluded)) }
    #expect(try await store.observations().count == 3)
    #expect(try await store.exportGPX() == data)
}

@Test func gpxBreaksTracksAtPausesGapsAndBadFixesAndNeverUsesCachedWiFiCoordinates() throws {
    let first = fix(0)
    var duplicate = first; duplicate.id = "duplicate"
    let samples = [first, duplicate, fix(60), fix(61, source: .paused), fix(62),
                   fix(63, accuracy: 900), fix(64), fix(700), fix(701, source: .recovery), fix(702),
                   fix(703, source: .wifi), fix(704, source: .visitArrival)]
    let xml = try XMLDocument(data: GPXExport.encode(places: [], observations: samples.reversed()))
    #expect(try xml.nodes(forXPath: "//trkseg").count == 5)
    #expect(try xml.nodes(forXPath: "//trkpt").count == 6)
    #expect(try xml.nodes(forXPath: "//rte").isEmpty == true)
}

@Test func gpxEscapesXMLFiltersInvalidPointsAndHandlesEmptyHistory() throws {
    let place = Place(name: "A\u{0}B\u{1F}C", coordinate: Coordinate(latitude: 0.00000001, longitude: 180))
    let invalid = Place(name: "Invalid", coordinate: Coordinate(latitude: .nan, longitude: 0))
    let xml = try XMLDocument(data: GPXExport.encode(places: [place, invalid], observations: [fix(0, coordinate: Coordinate(latitude: 91, longitude: 4))]))
    #expect(try xml.nodes(forXPath: "//wpt/name").first?.stringValue == "ABC")
    #expect(try xml.nodes(forXPath: "//wpt/@lat").first?.stringValue == "0.00000001")
    #expect(try xml.nodes(forXPath: "//wpt/@lon").first?.stringValue == "-180.00000000")
    #expect(try xml.nodes(forXPath: "//wpt").count == 1)
    #expect(try xml.nodes(forXPath: "//trk").isEmpty == true)
    let empty = try XMLDocument(data: GPXExport.encode(places: [], observations: []))
    #expect(try empty.nodes(forXPath: "//wpt | //trk").isEmpty == true)
}
