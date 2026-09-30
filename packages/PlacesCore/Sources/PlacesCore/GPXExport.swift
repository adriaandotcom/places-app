import Foundation

/// Interoperable GPX 1.1: saved places and measured fixes, never inferred paths.
public enum GPXExport {
    public static func encode(places: [Place], observations: [SensorObservation]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Places" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Places history</name><desc>Recorded location samples and saved places. Separate segments mark device changes, recording breaks or gaps longer than five minutes. No paths are estimated.</desc></metadata>

        """
        func attributes(_ coordinate: Coordinate) -> String {
            // GPX longitude is [-180, 180), while Core Location also accepts 180.
            let roundedLongitude = (coordinate.longitude * 100_000_000).rounded() / 100_000_000
            let longitude = roundedLongitude == 180 ? -180 : roundedLongitude
            // XML decimal values cannot use scientific notation or locale commas.
            return String(format: "lat=\"%.8f\" lon=\"%.8f\"", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, longitude)
        }
        for place in places.sorted(by: { $0.id < $1.id }) where place.coordinate.isValid {
            xml += "  <wpt \(attributes(place.coordinate))><name>\(escaped(place.name))</name><type>Saved place</type></wpt>\n"
        }
        var trackOpen = false, segmentOpen = false
        var previous: SensorObservation?
        func closeSegment() {
            if segmentOpen { xml += "    </trkseg>\n"; segmentOpen = false }
            previous = nil
        }
        for observation in observations.sorted(by: { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }) {
            if [.paused, .resumed, .recovery].contains(observation.source) { closeSegment(); continue }
            guard [.location, .significantChange].contains(observation.source) else { continue }
            guard let coordinate = observation.usableCoordinate,
                  observation.timestamp.timeIntervalSince1970.isFinite,
                  (-62_135_596_800...253_402_300_799).contains(observation.timestamp.timeIntervalSince1970) else {
                closeSegment(); continue
            }
            if let previous {
                let sameDevice = previous.companionDevice == observation.companionDevice
                    && previous.companionDeviceID == observation.companionDeviceID
                if sameDevice && previous.timestamp == observation.timestamp && previous.coordinate == coordinate { continue }
                let elapsed = observation.timestamp.timeIntervalSince(previous.timestamp)
                if !sameDevice || elapsed <= 0 || elapsed > 5 * 60 { closeSegment() }
            }
            if !trackOpen { xml += "  <trk><name>Recorded locations</name>\n"; trackOpen = true }
            if !segmentOpen { xml += "    <trkseg>\n"; segmentOpen = true }
            xml += "      <trkpt \(attributes(coordinate))><time>\(formatter.string(from: observation.timestamp))</time></trkpt>\n"
            previous = observation
        }
        closeSegment()
        if trackOpen { xml += "  </trk>\n" }
        xml += "</gpx>\n"
        return Data(xml.utf8)
    }

    private static func escaped(_ text: String) -> String {
        // XML 1.0 excludes control characters even when the user can type them.
        let valid = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            [9, 10, 13].contains($0.value) || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }))
        return valid.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}
