import Foundation
import Observation
import SQLite

@Observable
final class AO3TagSeedDatabaseConfig {
    static let shared = AO3TagSeedDatabaseConfig()

    struct Counts: Equatable {
        let canonicalTags: Int
        let synonyms: Int
        let hierarchyEdges: Int
        let subtagSections: Int
    }

    enum ValidationStatus: Equatable {
        case disabled
        case notConfigured
        case valid(Counts)
        case invalid(String)
    }

    enum SeedError: LocalizedError {
        case missingTables([String])

        var errorDescription: String? {
            switch self {
            case .missingTables(let tables):
                return "AO3 tag seed database is missing tables: \(tables.joined(separator: ", "))."
            }
        }
    }

    private enum Keys {
        static let enabled = "ao3TagSeedDatabase.enabled"
        static let path = "ao3TagSeedDatabase.path"
    }

    private let readLock = NSRecursiveLock()
    private var cachedReadDB: (path: String, conn: Connection)?

    var isEnabled: Bool = false {
        didSet {
            readLock.lock()
            cachedReadDB = nil
            readLock.unlock()
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            refreshValidation()
        }
    }

    var databasePath: String? {
        didSet {
            readLock.lock()
            cachedReadDB = nil
            readLock.unlock()
            if let databasePath, !databasePath.isEmpty {
                UserDefaults.standard.set(databasePath, forKey: Keys.path)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.path)
            }
            refreshValidation()
        }
    }

    private(set) var validationStatus: ValidationStatus = .notConfigured

    var databaseURL: URL? {
        guard let databasePath, !databasePath.isEmpty else { return nil }
        return URL(fileURLWithPath: databasePath)
    }

    private init() {
        loadFromDefaults()
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        let enabledValue: Bool = defaults.object(forKey: Keys.enabled) == nil
            ? false
            : defaults.bool(forKey: Keys.enabled)
        let pathValue = defaults.string(forKey: Keys.path)

        if Thread.isMainThread {
            isEnabled = enabledValue
            databasePath = pathValue
            refreshValidation()
        } else {
            // .shared may be first touched from a background actor (e.g.
            // AmbrosiaMetaDB). @Published setters publish unconditionally,
            // even during init, so these writes must happen on the main
            // thread regardless of which thread constructs the singleton.
            // All stored properties already have inline defaults, so self
            // is fully initialized by the time this method runs and is
            // safe to capture in the closure below.
            DispatchQueue.main.sync {
                self.isEnabled = enabledValue
                self.databasePath = pathValue
                self.refreshValidation()
            }
        }
    }

    func chooseDatabase(url: URL) {
        databasePath = url.path
        isEnabled = true
    }

    func clearDatabase() {
        databasePath = nil
        isEnabled = false
    }

    func refreshValidation() {
        let newStatus: ValidationStatus
        if !isEnabled {
            newStatus = .disabled
        } else if let databaseURL {
            do {
                let counts = try Self.counts(url: databaseURL)
                newStatus = .valid(counts)
            } catch {
                newStatus = .invalid(error.localizedDescription)
            }
        } else {
            newStatus = .notConfigured
        }
        setValidationStatus(newStatus)
    }

    private func setValidationStatus(_ status: ValidationStatus) {
        if Thread.isMainThread {
            validationStatus = status
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.validationStatus = status
            }
        }
    }

    func validDatabaseURLIfEnabled() -> URL? {
        guard isEnabled, let databaseURL else { return nil }
        do {
            try Self.validate(url: databaseURL)
            return databaseURL
        } catch {
            refreshValidation()
            return nil
        }
    }

    static func validate(url: URL) throws {
        let db = try Connection(url.path, readonly: true)
        let rows = try db.prepare("SELECT name FROM sqlite_master WHERE type='table'").map { $0[0] as? String ?? "" }
        let tables = Set(rows)
        let required = ["canonical_tags", "tag_synonyms", "tag_parent_links", "tag_subtag_sections"]
        let missing = required.filter { !tables.contains($0) }
        guard missing.isEmpty else { throw SeedError.missingTables(missing) }
    }

    static func counts(url: URL) throws -> Counts {
        try validate(url: url)
        let db = try Connection(url.path, readonly: true)
        return Counts(
            canonicalTags: try count("canonical_tags", db: db),
            synonyms: try count("tag_synonyms", db: db),
            hierarchyEdges: try count("tag_parent_links", db: db),
            subtagSections: try count("tag_subtag_sections", db: db)
        )
    }

    static func identity(for url: URL) throws -> String {
        // `URL.resourceValues(forKeys:)` caches values on the URL value itself,
        // so a second call against the same URL instance (or a copy sharing its
        // cache) can return stale size/mtime after the file underneath has
        // changed. FileManager's attributesOfItem(atPath:) always stats the
        // file fresh, so use that instead.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? 0
        let modifiedDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let modified = Int(modifiedDate.timeIntervalSince1970)
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    private static func count(_ table: String, db: Connection) throws -> Int {
        let value = try db.scalar("SELECT COUNT(*) FROM \(table)")
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }

    // MARK: - Direct Read-Only Queries (Zero Data Duplication)

    private func readConnection() -> Connection? {
        readLock.lock()
        defer { readLock.unlock() }
        guard let url = validDatabaseURLIfEnabled() else {
            cachedReadDB = nil
            return nil
        }
        if let cached = cachedReadDB, cached.path == url.path {
            return cached.conn
        }
        guard let conn = try? Connection(url.path, readonly: true) else {
            cachedReadDB = nil
            return nil
        }
        cachedReadDB = (url.path, conn)
        return conn
    }

    func canonicalTag(for term: String) -> String {
        readLock.lock()
        defer { readLock.unlock() }
        guard let db = readConnection() else { return term }
        let sql = """
            SELECT c.name
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE LOWER(s.synonym) = LOWER(?)
            LIMIT 1
            """
        if let row = (try? db.prepare(sql, [term as Binding?]).map { $0 })?.first,
           let canonical = row[0] as? String {
            return canonical
        }
        return term
    }

    func expandedTerms(for term: String) -> [String] {
        readLock.lock()
        defer { readLock.unlock() }
        guard let db = readConnection() else { return [term] }
        let sql = """
            WITH root(id, name) AS (
                SELECT id, name FROM canonical_tags WHERE LOWER(name) = LOWER(?)
                UNION
                SELECT c.id, c.name
                FROM tag_synonyms s
                JOIN canonical_tags c ON c.id = s.canonical_id
                WHERE LOWER(s.synonym) = LOWER(?)
            )
            SELECT name FROM root
            UNION
            SELECT synonym
            FROM tag_synonyms
            WHERE canonical_id IN (SELECT id FROM root)
            """
        guard let rows = try? db.prepare(sql, [term as Binding?, term as Binding?]).map({ $0 }) else {
            return [term]
        }
        var seen = Set<String>()
        var terms: [String] = []
        for row in rows {
            guard let value = row[0] as? String else { continue }
            if seen.insert(value.lowercased()).inserted { terms.append(value) }
        }
        return terms.isEmpty ? [term] : terms
    }

    func expandedTermsBatch(for tags: [String]) -> [String: [String]] {
        guard !tags.isEmpty else { return [:] }
        readLock.lock()
        defer { readLock.unlock() }
        guard let db = readConnection() else {
            return LibraryQueryHelpers.indexed(tags.map { ($0, [$0]) })
        }

        let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
        let lowerBindings: [Binding?] = tags.map { $0.lowercased() as Binding? }

        let rootSQL = """
            SELECT LOWER(name) AS matched_term, id, name
            FROM canonical_tags
            WHERE LOWER(name) IN (\(placeholders))
            UNION ALL
            SELECT LOWER(s.synonym) AS matched_term, c.id, c.name
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE LOWER(s.synonym) IN (\(placeholders))
            """
        guard let rootRows = try? db.prepare(rootSQL, lowerBindings + lowerBindings).map({ $0 }) else {
            return LibraryQueryHelpers.indexed(tags.map { ($0, [$0]) })
        }

        var rootIDsByMatchedTerm: [String: Set<Int64>] = [:]
        var canonicalNameByRootID: [Int64: String] = [:]
        for row in rootRows {
            guard let matchedTerm = row[0] as? String,
                  let rootID = (row[1] as? Int64) ?? (row[1] as? Int).map(Int64.init),
                  let canonicalName = row[2] as? String else { continue }
            rootIDsByMatchedTerm[matchedTerm, default: []].insert(rootID)
            canonicalNameByRootID[rootID] = canonicalName
        }

        let allRootIDs = Array(Set(canonicalNameByRootID.keys))
        var synonymsByRootID: [Int64: [String]] = [:]
        if !allRootIDs.isEmpty {
            let idPlaceholders = allRootIDs.map { _ in "?" }.joined(separator: ", ")
            let synonymSQL = """
                SELECT canonical_id, synonym
                FROM tag_synonyms
                WHERE canonical_id IN (\(idPlaceholders))
                """
            let idBindings: [Binding?] = allRootIDs.map { $0 as Binding? }
            if let synonymRows = try? db.prepare(synonymSQL, idBindings).map({ $0 }) {
                for row in synonymRows {
                    guard let rootID = (row[0] as? Int64) ?? (row[0] as? Int).map(Int64.init),
                          let synonym = row[1] as? String else { continue }
                    synonymsByRootID[rootID, default: []].append(synonym)
                }
            }
        }

        var result: [String: [String]] = [:]
        for tag in tags {
            let matchedTerm = tag.lowercased()
            guard let rootIDs = rootIDsByMatchedTerm[matchedTerm], !rootIDs.isEmpty else {
                result[tag] = [tag]
                continue
            }
            var seen = Set<String>()
            var terms: [String] = []
            for rootID in rootIDs {
                if let name = canonicalNameByRootID[rootID], seen.insert(name.lowercased()).inserted {
                    terms.append(name)
                }
                for synonym in synonymsByRootID[rootID] ?? [] where seen.insert(synonym.lowercased()).inserted {
                    terms.append(synonym)
                }
            }
            result[tag] = terms.isEmpty ? [tag] : terms
        }
        return result
    }
}
