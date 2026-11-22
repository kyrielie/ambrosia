// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct TagRelevanceTargets: Equatable, Sendable {
    var exact: [String] = []
    var contains: [String] = []
    var isEmpty: Bool { exact.isEmpty && contains.isEmpty }

    static func make(
        expression: FilterExpression?,
        query: SearchQuery,
        expansions: [String: [String]]
    ) -> TagRelevanceTargets {
        var exact: [String] = []
        var contains: [String] = []
        var seenExact = Set<String>()
        var seenContains = Set<String>()

        func appendExact(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard AO3TagKind.classify(trimmed) == .regular else { return }
            let lower = trimmed.lowercased()
            if seenExact.insert(lower).inserted {
                exact.append(trimmed)
            }
        }

        func appendContains(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard AO3TagKind.classify(trimmed) == .regular else { return }
            let lower = trimmed.lowercased()
            if seenContains.insert(lower).inserted {
                contains.append(trimmed)
            }
        }

        if let expression {
            for group in expression.groups {
                for rule in group.rules where rule.field == .tag && rule.isComplete {
                    let synonyms = expansions[rule.value] ?? []
                    switch rule.op {
                    case .equals:
                        appendExact(rule.value)
                        for syn in synonyms {
                            appendExact(syn)
                        }
                    case .contains:
                        appendContains(rule.value)
                        for syn in synonyms {
                            appendContains(syn)
                        }
                    default:
                        break
                    }
                }
            }
        }

        for term in query.scopedTagTerms {
            let termSynonyms = expansions[term.value]
                ?? expansions[term.value.trimmingCharacters(in: .whitespacesAndNewlines)]
                ?? []
            switch term.mode {
            case .exact:
                appendExact(term.value)
                for syn in termSynonyms {
                    appendExact(syn)
                }
            case .contains:
                appendContains(term.value)
                for syn in termSynonyms {
                    appendContains(syn)
                }
            case .regex, .word:
                break
            }
        }

        return TagRelevanceTargets(exact: exact, contains: contains)
    }
}
