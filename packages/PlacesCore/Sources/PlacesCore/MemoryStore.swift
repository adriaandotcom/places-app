import Foundation
import GRDB

extension PlacesStore {
    public func tripIDs(visiting placeID: String, now: Date = Date()) throws -> [String] {
        try queue.read { db in
            let items = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
            let visits = InferenceEngine.applying(edits, to: items).filter { $0.kind == .stay && $0.placeID == placeID }
            return try MemorySQL.trips(db).filter { trip in
                !trip.hidden && visits.contains { $0.start < (trip.end ?? now) && ($0.end ?? now) > trip.start }
            }.map(\.id)
        }
    }
    public func memoryLibrary(now: Date = Date()) throws -> MemoryLibrary {
        try queue.write { db in
            let existing = try MemorySQL.trips(db)
            let places = try StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
            let inferred = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
            let corrections = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
            let items = InferenceEngine.applying(corrections, to: inferred)
            var zones: [String: String] = [:]
            // Only load one source record per stay, rather than the entire GPS history.
            for item in items where item.kind == .stay {
                if let evidence = item.evidenceIDs.first,
                   let source = try StoreSQL.decodeAll(SensorObservation.self, db: db,
                    sql: "SELECT payload FROM observations WHERE id = ?", arguments: [evidence]).first {
                    zones[item.id] = source.timezoneIdentifier
                }
            }
            let trips = TripDetection.reconcile(TripDetection.detect(items: items, places: places, timeZones: zones, now: now), existing: existing)
            for trip in trips where !existing.contains(trip) { try MemorySQL.saveTrip(trip, db: db) }
            var library = MemoryLibrary()
            library.trips = trips
            library.people = try MemorySQL.people(db)
            library.memories = try MemorySQL.memories(db).map { memory in
                var memory = memory
                if memory.tripID == nil, let anchor = memory.visitStart,
                   let visit = items.first(where: { $0.start <= anchor && ($0.end ?? .distantFuture) > anchor }) {
                    let placeID = visit.kind == .stay ? visit.placeID : nil
                    if memory.placeID != placeID {
                        memory.placeID = placeID
                        try MemorySQL.saveMemory(memory, db: db)
                    }
                }
                return memory
            }
            return library
        }
    }

    public func saveTrip(_ trip: Trip) throws {
        guard !trip.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              trip.start.timeIntervalSince1970.isFinite,
              trip.end.map({ $0.timeIntervalSince1970.isFinite && $0 > trip.start }) ?? true else { throw MemoryError.invalidTrip }
        try queue.write { db in
            try MemorySQL.checkPeople(trip.personIDs, db: db)
            try MemorySQL.saveTrip(trip, db: db)
        }
    }
    public func savePerson(_ person: MemoryPerson) throws {
        guard !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.invalidPerson }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO people(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                           arguments: [person.id, try StoreSQL.encode(person)])
        }
    }
    public func deletePerson(id: String) throws {
        try queue.write { db in
            for var trip in try MemorySQL.trips(db) where trip.personIDs.contains(id) {
                trip.personIDs.removeAll { $0 == id }; try MemorySQL.saveTrip(trip, db: db)
            }
            for var memory in try MemorySQL.memories(db) where memory.personIDs.contains(id) {
                memory.personIDs.removeAll { $0 == id }; try MemorySQL.saveMemory(memory, db: db)
            }
            try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
        }
    }
    public func saveMemory(_ memory: PlaceMemory, adding photos: [MemoryPhoto] = [], importing files: [MemoryPhotoFile] = []) throws {
        guard memory.date.timeIntervalSince1970.isFinite, memory.visitStart?.timeIntervalSince1970.isFinite != false,
              !memory.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !memory.photoIDs.isEmpty || !memory.personIDs.isEmpty,
              memory.tripID != nil || memory.placeID != nil || memory.visitStart != nil else { throw MemoryError.invalidMemory }
        let addedIDs = photos.map(\.id) + files.map(\.id)
        guard Set(memory.photoIDs).count == memory.photoIDs.count,
              Set(addedIDs).count == addedIDs.count, Set(addedIDs).isSubset(of: Set(memory.photoIDs))
        else { throw MemoryError.invalidPhoto }
        try queue.write { db in
            try MemorySQL.checkPeople(memory.personIDs, db: db)
            if let id = memory.tripID, try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM trips WHERE id = ?)", arguments: [id])! { throw MemoryError.invalidMemory }
            if let id = memory.placeID, try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM places WHERE id = ?)", arguments: [id])! { throw MemoryError.invalidMemory }
            let owned = try String.fetchAll(db, sql: "SELECT id FROM memoryPhotos WHERE memoryID = ?", arguments: [memory.id])
            guard Set(memory.photoIDs).isSubset(of: Set(owned + addedIDs)) else { throw MemoryError.invalidPhoto }
            try MemorySQL.saveMemory(memory, db: db)
            for id in owned where !memory.photoIDs.contains(id) {
                try db.execute(sql: "DELETE FROM memoryPhotos WHERE id = ?", arguments: [id])
            }
            // INSERT, not REPLACE: a caller cannot move another memory's photo by reusing its ID.
            for photo in photos {
                try MemorySQL.insertPhoto(photo, memoryID: memory.id, db: db)
            }
            for file in files {
                guard try file.jpegURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 450_000,
                      try file.thumbnailURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 50_000 else { throw MemoryError.invalidPhoto }
                let photo = try MemoryPhoto(id: file.id, jpeg: Data(contentsOf: file.jpegURL), thumbnail: Data(contentsOf: file.thumbnailURL))
                try MemorySQL.insertPhoto(photo, memoryID: memory.id, db: db)
            }
        }
    }
    public func deleteMemory(id: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id]) }
    }
    public func photoData(id: String, thumbnail: Bool = false) throws -> Data? {
        try queue.read { try Data.fetchOne($0, sql: thumbnail ? "SELECT thumbnail FROM memoryPhotos WHERE id = ?" : "SELECT jpeg FROM memoryPhotos WHERE id = ?", arguments: [id]) }
    }
    func memoryArchive() throws -> MemoryArchive {
        try queue.read { db in
            let photos = try Row.fetchAll(db, sql: "SELECT id, jpeg, thumbnail FROM memoryPhotos").map {
                MemoryPhoto(id: $0["id"], jpeg: $0["jpeg"], thumbnail: $0["thumbnail"])
            }
            return try MemoryArchive(trips: MemorySQL.trips(db), people: MemorySQL.people(db), memories: MemorySQL.memories(db), photos: photos)
        }
    }
}

enum MemorySQL {
    static func insertPhoto(_ photo: MemoryPhoto, memoryID: String, db: Database) throws {
        guard !photo.jpeg.isEmpty, photo.jpeg.count <= 450_000, !photo.thumbnail.isEmpty, photo.thumbnail.count <= 50_000 else { throw MemoryError.invalidPhoto }
        try db.execute(sql: "INSERT INTO memoryPhotos(id, memoryID, jpeg, thumbnail) VALUES (?, ?, ?, ?)",
                       arguments: [photo.id, memoryID, photo.jpeg, photo.thumbnail])
    }
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE trips (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE people (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE memories (id TEXT PRIMARY KEY, date REAL NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE memoryPhotos (id TEXT PRIMARY KEY, memoryID TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                jpeg BLOB NOT NULL, thumbnail BLOB NOT NULL);
            CREATE INDEX memoryPhotos_memory ON memoryPhotos(memoryID);
            """)
    }
    static func trips(_ db: Database) throws -> [Trip] { try StoreSQL.decodeAll(Trip.self, db: db, sql: "SELECT payload FROM trips") }
    static func people(_ db: Database) throws -> [MemoryPerson] {
        try StoreSQL.decodeAll(MemoryPerson.self, db: db, sql: "SELECT payload FROM people").sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func memories(_ db: Database) throws -> [PlaceMemory] { try StoreSQL.decodeAll(PlaceMemory.self, db: db, sql: "SELECT payload FROM memories ORDER BY date DESC") }
    static func saveTrip(_ trip: Trip, db: Database) throws {
        try db.execute(sql: "INSERT INTO trips(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [trip.id, try StoreSQL.encode(trip)])
    }
    static func saveMemory(_ memory: PlaceMemory, db: Database) throws {
        try db.execute(sql: "INSERT INTO memories(id, date, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET date = excluded.date, payload = excluded.payload",
                       arguments: [memory.id, memory.date.timeIntervalSince1970, try StoreSQL.encode(memory)])
    }
    static func checkPeople(_ ids: [String], db: Database) throws {
        let known = Set(try String.fetchAll(db, sql: "SELECT id FROM people"))
        guard Set(ids).isSubset(of: known) else { throw MemoryError.invalidPerson }
    }
}
