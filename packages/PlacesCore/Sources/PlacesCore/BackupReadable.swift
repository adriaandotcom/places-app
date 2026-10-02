import Foundation
import GRDB

/// Static, escaped HTML works directly from disk, without JavaScript, a server,
/// fonts, map tiles, or any network requests. Large timelines are split by month.
enum BackupReadable {
    static func write(db: Database, root: URL, counts: [String: Int]) throws {
        var placeNames: [String: String] = [:]
        var peopleNames: [String: String] = [:]
        var tripNames: [String: String] = [:]
        func picture(_ data: Data?, alt: String) throws -> String {
            guard let data else { return "" }
            return "<img loading=\"lazy\" src=\"\(try BackupIO.media(data, root: root))\" alt=\"\(escape(alt))\">"
        }
        try page("places.html", title: "Your places", root: root) { output in
            try records(Place.self, db: db, sql: "SELECT payload FROM places ORDER BY name") { place in
                placeNames[place.id] = place.name
                try output.text("<article><h2>\(escape(place.name))</h2><p>\(escape(place.address))</p>\(try picture(place.photoJPEG, alt: place.name))<p>\(place.coordinate.latitude), \(place.coordinate.longitude) · Radius: \(place.radius) metres</p><p>\(place.area == nil ? "Circular recognition area" : "Custom polygon recognition area")</p></article>")
            }
        }
        try page("people.html", title: "Your people", root: root) { output in
            try records(MemoryPerson.self, db: db, sql: "SELECT payload FROM people") { person in
                peopleNames[person.id] = person.name
                try output.text("<article><h2>\(escape(person.name))</h2>\(try picture(person.avatarJPEG, alt: person.name))<p class=\"note\">\(escape(person.detail))</p></article>")
            }
        }
        try page("trips.html", title: "Your trips", root: root) { output in
            try records(Trip.self, db: db, sql: "SELECT payload FROM trips") { trip in
                tripNames[trip.id] = trip.title
                try output.text("<article><h2>\(escape(trip.title))</h2><p>\(date(trip.start)) – \(trip.end.map(date) ?? "Ongoing")\(trip.hidden ? " · Hidden in Places" : "")</p>\(try picture(trip.photoJPEG, alt: trip.title))<p>\(escape(trip.personIDs.compactMap { peopleNames[$0] }.joined(separator: ", ")))</p></article>")
            }
        }
        try page("memories.html", title: "Your memories", root: root) { output in
            try records(PlaceMemory.self, db: db, sql: "SELECT payload FROM memories ORDER BY date DESC") { memory in
                let title = memory.placeID.flatMap { placeNames[$0] } ?? memory.tripID.flatMap { tripNames[$0] } ?? "Memory"
                try output.text("<article><h2>\(escape(title))</h2><p>\(date(memory.date))</p><p class=\"note\">\(escape(memory.text))</p><p>\(escape(memory.linkedPersonIDs.compactMap { peopleNames[$0] }.joined(separator: ", ")))</p><div class=\"photos\">")
                for id in memory.orderedPhotoIDs {
                    try autoreleasepool {
                        if let data = try Data.fetchOne(db, sql: "SELECT jpeg FROM memoryPhotos WHERE id = ?", arguments: [id]) {
                            let path = try BackupIO.media(data, root: root)
                            let caption = memory.photoDetails?[id]?.caption ?? ""
                            try output.text("<figure><a href=\"\(path)\"><img loading=\"lazy\" src=\"\(path)\" alt=\"\(escape(caption.isEmpty ? title : caption))\"></a><figcaption>\(escape(caption))</figcaption></figure>")
                        }
                    }
                }
                try output.text("</div></article>")
            }
        }
        let months = try timeline(db: db, root: root, places: placeNames)
        try page("index.html", title: "Your Places backup", root: root) { output in
            try output.text("<p>Your history, saved by you. These pages work offline. Dates below use UTC so the same file reads consistently on any computer.</p><p><strong>Keep this folder private.</strong> It contains exact locations, Wi-Fi identifiers, notes, people and saved photos. It is not encrypted.</p><div class=\"summary\">")
            for (table, label, link) in [("places", "Places", "places.html"), ("memories", "Memories", "memories.html"), ("trips", "Trips", "trips.html"), ("people", "People", "people.html")] {
                let count = counts[table] ?? 0
                let title = count == 1 ? ["places": "Place", "memories": "Memory", "trips": "Trip", "people": "Person"][table]! : label
                try output.text("<a href=\"\(link)\">\(count) \(title)</a>")
            }
            try output.text("</div><h2>Timeline</h2><ul>")
            for path in months.reversed() { try output.text("<li><a href=\"\(path)\">\(path.replacingOccurrences(of: "timeline-", with: "").replacingOccurrences(of: ".html", with: ""))</a></li>") }
            try output.text("</ul><h2>Restore on another iPhone</h2><p>Install Places, then choose Restore a backup during setup, or Settings → Your data → Backup and restore → Restore a backup. Select the original ZIP and review it before confirming. Restore replaces the Places data on that phone.</p><p>Recording, photo scanning, Apple Maps and online lookups stay off until you enable them. Pair companion devices again and download your maps separately.</p><h2>Readable source files</h2><p>Every stored record is also included as JSON Lines: one JSON object per line. Saved photos are ordinary JPEG files. You can open these files with a text editor or your own tools.</p><ul>")
            for table in BackupTable.all { try output.text("<li><a href=\"\(table.path)\">\(table.name)</a> · \(counts[table.name] ?? 0) records</li>") }
            try output.text("</ul><p><a href=\"README.txt\">About this backup</a></p>")
        }
        try Data("""
        PLACES COMPLETE BACKUP

        Open index.html in a browser to browse your places, timeline, people,
        trips, memories and photos. Nothing in these pages connects to the internet.
        Unzip the whole archive first, keeping the folder structure intact.

        To transfer to another iPhone: install Places, choose Restore a backup
        in setup or Settings > Your data > Backup and restore, and select the
        original ZIP. Review the counts and confirm replacement of that phone's
        Places data. Export its current history first if you want to keep it.

        INCLUDES: all recorded evidence (including imported companion and photo
        locations), visits, routes, corrections, polygon areas, Wi-Fi knowledge,
        trips, people, notes, mentions, photo order/captions, every photo saved
        inside Places, preferences and photo suggestion review state.

        EXCLUDES: downloaded map packs, device permissions, companion pairing
        secrets, temporary diagnostics and images only in your system Photos
        library that were never saved to a Places memory/avatar/place/trip.
        Pair companions again and choose your privacy settings on the new phone.
        Restoring does not start recording, network access or photo scanning.

        PRIVACY: this ZIP is not encrypted. Anyone with it can read your exact
        history and photos. Share it only with yourself or someone you trust.
        Saving it in a cloud folder may sync it through that provider.

        FORMAT: manifest.json describes version 1, counts and SHA-256 checksums.
        data/*.jsonl contains one complete database record per line. Payloads
        use Swift Codable dates: seconds since 2001-01-01T00:00:00Z. Indexed
        timestamp/start/end/date/capturedAt/createdAt columns use seconds since
        1970-01-01T00:00:00Z. Both retain fractional precision. Embedded avatar
        images in payloads use base64. memoryPhotos records refer to JPEG files
        in photos/. The HTML pages use UTC. Do not edit files intended for restore.
        The HTML and extracted avatar copies are for browsing; JSON records and
        referenced memory photos are authoritative for restoring the app.

        """.utf8).write(to: root.appendingPathComponent("README.txt"))
    }

    private static func timeline(db: Database, root: URL, places: [String: String]) throws -> [String] {
        let bounds = try Row.fetchOne(db, sql: "SELECT MIN(start) AS first, MAX(finish) AS last FROM (SELECT start, COALESCE(end, ?) AS finish FROM timeline UNION ALL SELECT start, end AS finish FROM overrides)", arguments: [Date().timeIntervalSince1970])
        guard let first: Double = bounds?["first"], let last: Double = bounds?["last"] else { return [] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard var month = calendar.dateInterval(of: .month, for: Date(timeIntervalSince1970: first))?.start else { throw BackupError.invalid }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM"
        var result: [String] = []
        while month.timeIntervalSince1970 <= last {
            try Task.checkCancellation()
            guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month, result.count < 12_000 else { throw BackupError.tooLarge }
            let arguments: StatementArguments = [next.timeIntervalSince1970, month.timeIntervalSince1970]
            let items = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline WHERE start < ? AND (end IS NULL OR end > ?) ORDER BY start", arguments: arguments)
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides WHERE start < ? AND end > ? ORDER BY createdAt", arguments: arguments)
            let path = "timeline-\(formatter.string(from: month)).html"; result.append(path)
            try page(path, title: "Timeline · \(formatter.string(from: month))", root: root) { output in
                for item in InferenceEngine.applying(edits, to: items) where item.start < next && (item.end ?? .distantFuture) > month {
                    let title = item.kind == .stay ? item.placeID.flatMap { places[$0] } ?? "Somewhere new" : item.kind == .journey ? item.mode.title : "Unknown interval"
                    try output.text("<article><h2>\(escape(title))</h2><p>\(date(max(month, item.start))) – \(item.end.map { date(min($0, next)) } ?? "No departure recorded")</p></article>")
                }
            }
            month = next
        }
        return result
    }

    // Do not retain every embedded place/trip/avatar image while generating pages.
    private static func records<T: Decodable>(_ type: T.Type, db: Database, sql: String, body: (T) throws -> Void) throws {
        let cursor = try Data.fetchCursor(db, sql: sql)
        while let data = try cursor.next() {
            try Task.checkCancellation()
            try autoreleasepool { try body(JSONDecoder().decode(type, from: data)) }
        }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    private static func date(_ value: Date) -> String {
        value.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon)).replacingOccurrences(of: "T", with: " at ") + " UTC"
    }
    private static func page(_ path: String, title: String, root: URL, body: (FileHandle) throws -> Void) throws {
        let output = try BackupIO.writer(root.appendingPathComponent(path)); defer { try? output.close() }
        try output.text("""
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(escape(title)) · Places</title><style>
        body{font:17px/1.6 system-ui,sans-serif;max-width:1000px;margin:auto;padding:28px;background:#faf7ee;color:#29261e}
        a{color:#287547}h1{font-size:2.3rem;line-height:1.2}h2{font-size:1.3rem}article{background:white;border-radius:20px;padding:24px;margin:20px 0}
        img{max-width:100%;max-height:360px;border-radius:12px;object-fit:contain}figure{margin:0}figcaption{font-size:.9rem}.photos{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px}.note{white-space:pre-wrap}.summary{display:flex;flex-wrap:wrap;gap:24px}nav{margin-bottom:24px}p{overflow-wrap:anywhere}
        @media(prefers-color-scheme:dark){body{background:#191c18;color:#f4f0e4}article{background:#272c24}a{color:#8cdaa9}}
        </style><nav><a href="index.html">Places backup</a> · <a href="places.html">Places</a> · <a href="memories.html">Memories</a> · <a href="trips.html">Trips</a> · <a href="people.html">People</a></nav><main><h1>\(escape(title))</h1>
        """)
        try body(output)
        try output.text("</main></html>")
    }
}

private extension FileHandle {
    func text(_ value: String) throws { try write(contentsOf: Data(value.utf8)) }
}
