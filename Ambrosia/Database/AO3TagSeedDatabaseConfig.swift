import Foundation
import SQLite

final class AO3TagSeedDatabaseConfig: ObservableObject {
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

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            refreshValidation()
        }
    }

    @Published var databasePath: String? {
        didSet {
            if let databasePath, !databasePath.isEmpty {
                UserDefaults.standard.set(databasePath, forKey: Keys.path)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.path)
            }
            refreshValidation()
        }
    }

    @Published private(set) var validationStatus: ValidationStatus = .notConfigured

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
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = Int((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    private static func count(_ table: String, db: Connection) throws -> Int {
        let value = try db.scalar("SELECT COUNT(*) FROM \(table)")
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }
}
