import Foundation

/// Maps AO3 language codes to valid IETF BCP 47 language tags per the `epub-otwarchive` spec.
enum AO3LanguageMap {

    /// Maps AO3 language short codes to standard IETF BCP 47 tags.
    static func bcp47Tag(for ao3Code: String?) -> String {
        guard let code = ao3Code?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return "en"
        }

        // Known AO3 overrides where AO3 short code != BCP 47
        switch code {
        case "div": return "dv"         // Maldivian
        case "sla": return "cu"         // Church Slavic
        case "sun": return "su"         // Sundanese
        case "tir": return "ti"         // Tigrinya
        case "qnv": return "art-x-navi" // Na'vi
        default:
            return code
        }
    }
}
