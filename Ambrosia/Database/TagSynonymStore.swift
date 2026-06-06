import Foundation

/// Persists user-defined tag synonyms in UserDefaults.
///
/// Synonyms let the user map multiple tag spellings to a canonical tag name
/// for filtering purposes (e.g. "Coffee!AU" → "Coffee Shop AU").
///
/// Storage format: [String: [String]] dictionary JSON-encoded in UserDefaults.
/// Key = canonical tag name (lowercased). Value = array of synonym strings.
///
/// Never stored as a @Model — synonyms are a user preference, not library data.
final class TagSynonymStore {

    static let shared = TagSynonymStore()
    private init() {}

    private let defaultsKey = "tagSynonyms"

    // MARK: - Read

    /// Returns all synonyms registered for a canonical tag name.
    func synonyms(for canonical: String) -> [String] {
        all[canonical.lowercased()] ?? []
    }

    /// Resolves a query string to its canonical tag name (or returns it unchanged).
    func canonical(for input: String) -> String {
        let lower = input.lowercased()
        for (canonical, syns) in all {
            if syns.map({ $0.lowercased() }).contains(lower) {
                return canonical
            }
        }
        return input
    }

    /// Returns every known synonym → canonical mapping, flattened.
    /// Used to expand a search value into all equivalent strings.
    func allEquivalents(for input: String) -> [String] {
        let lower = input.lowercased()
        // Check if input is itself a canonical key
        if let syns = all[lower] {
            return [input] + syns
        }
        // Check if input is a synonym for some canonical
        for (canonical, syns) in all {
            if syns.map({ $0.lowercased() }).contains(lower) {
                return [canonical] + syns
            }
        }
        return [input]
    }

    // MARK: - Write

    func add(synonym: String, for canonical: String) {
        var store = all
        let key = canonical.lowercased()
        var syns = store[key] ?? []
        if !syns.contains(synonym) { syns.append(synonym) }
        store[key] = syns
        save(store)
    }

    func remove(synonym: String, from canonical: String) {
        var store = all
        let key = canonical.lowercased()
        store[key] = store[key]?.filter { $0 != synonym }
        if store[key]?.isEmpty == true { store.removeValue(forKey: key) }
        save(store)
    }

    func removeAll(for canonical: String) {
        var store = all
        store.removeValue(forKey: canonical.lowercased())
        save(store)
    }

    // MARK: - Storage

    var all: [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ dict: [String: [String]]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
