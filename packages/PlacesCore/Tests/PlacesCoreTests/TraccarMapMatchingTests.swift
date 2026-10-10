import Foundation
import Testing
@testable import PlacesCore

private func matchingPoint(_ seconds: Double, _ longitude: Double = 4.88, accuracy: Double = 10) -> TraccarPoint {
    TraccarPoint(timestamp: Date(timeIntervalSince1970: 1_780_000_000 + seconds),
                 coordinate: .init(latitude: 52.36, longitude: longitude), accuracy: accuracy)
}

@Test func orangeTraceBreaksAtMissingEvidenceAndPoorAccuracy() {
    let points = [matchingPoint(0), matchingPoint(10, 4.8801), matchingPoint(20, accuracy: 500),
                  matchingPoint(30, 4.8802), matchingPoint(40, 4.8803),
                  matchingPoint(400, 4.881), matchingPoint(410, 4.8811)]
    let trace = TraccarMatchingTrace(points: points.reversed(), mode: .walking)
    #expect(trace.sections.map { $0.map(\.timestamp) } == [[points[0].timestamp, points[1].timestamp],
        [points[3].timestamp, points[4].timestamp], [points[5].timestamp, points[6].timestamp]])
    #expect(trace.excludedPointCount == 1)
}

@Test func orangeTraceDoesNotConnectTeleportOrDuplicateTimestamp() {
    let points = [matchingPoint(0), matchingPoint(10, 4.8801), matchingPoint(11, 5.5),
                  matchingPoint(20, 5.5001), matchingPoint(20, 5.5002), matchingPoint(30, 5.5003)]
    let trace = TraccarMatchingTrace(points: points + [points[0]], mode: .walking)
    #expect(trace.sections.count == 3)
    #expect(trace.sections.allSatisfy { $0.count == 2 })
}

@Test func matchingRequestPreservesMeasuredTimesAndHasOnlyOrangePoints() throws {
    let points = [matchingPoint(0), matchingPoint(7.5, 4.8801)]
    let data = Data(try TraccarMatchingTrace.request(for: points, mode: .bicycle).utf8)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let shape = try #require(object["shape"] as? [[String: Any]])
    #expect(shape.count == 2)
    #expect(shape[1]["time"] as? Double == points[1].timestamp.timeIntervalSince1970)
    #expect(object["costing"] as? String == "bicycle")
    #expect(object["use_timestamps"] as? Bool == true)
    #expect(!String(decoding: data, as: UTF8.self).contains("edge_index"))
}

@Test func matchedDistanceUsesGeometryAndDurationUsesEvidence() throws {
    let response = """
    {"shape":"_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI","units":"kilometers",
     "edges":[{"length":1.25}],"matched_points":[
      {"type":"matched","distance_from_trace_point":4},
      {"type":"matched","distance_from_trace_point":5}],"duration":9999}
    """
    let result = try TraccarMatchedSection.decode(response, points: [matchingPoint(0), matchingPoint(60)])
    #expect(result.coordinates.count == 3)
    #expect(result.coordinates[0].latitude == 38.5)
    #expect(result.distanceMeters == 1_250)
    #expect(result.observedSeconds == 60)
}

@Test func disconnectedOrUnmatchedRoutesAreRejected() {
    for match in ["{\"type\":\"unmatched\"}",
                  "{\"type\":\"matched\",\"distance_from_trace_point\":1,\"begin_route_discontinuity\":true}",
                  "{\"type\":\"matched\",\"distance_from_trace_point\":1000}"] {
        let response = "{\"shape\":\"????\",\"units\":\"kilometers\",\"edges\":[{\"length\":1}],\"matched_points\":[\(match),\(match)]}"
        #expect(throws: TraccarMatchingError.incompleteMatch) {
            try TraccarMatchedSection.decode(response, points: [matchingPoint(0), matchingPoint(30)])
        }
    }
}
