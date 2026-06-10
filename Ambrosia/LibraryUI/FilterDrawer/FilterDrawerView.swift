import SwiftUI
import SwiftData

// MARK: - FilterDrawerView

struct FilterDrawerView: View {
    @Binding var expression: FilterExpression
    var onApply: () -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Label("Filter Library", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            // Group conjunction picker (only shown when 2+ groups)
            if expression.groups.count >= 2 {
                HStack {
                    Text("Groups joined by")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $expression.groupConjunction) {
                        Text("OR  (any group)").tag(FilterConjunction.or)
                        Text("AND (all groups)").tag(FilterConjunction.and)
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
            }

            ScrollView {
                VStack(spacing: 0) {
                    if expression.groups.isEmpty {
                        Text("No filters.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(20)
                    } else {
                        ForEach($expression.groups) { $group in
                            GroupSection(
                                group: $group,
                                showGroupLabel: expression.groups.count > 1,
                                groupIndex: expression.groups.firstIndex(where: { $0.id == group.id }) ?? 0,
                                onDelete: {
                                    expression.groups.removeAll { $0.id == group.id }
                                }
                            )
                            if group.id != expression.groups.last?.id {
                                // Group separator showing the between-group conjunction
                                HStack {
                                    VStack { Divider() }
                                    Text(expression.groupConjunction.rawValue)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                    VStack { Divider() }
                                }
                                .padding(.horizontal, 20).padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 420)

            Divider()

            // Footer
            HStack {
                Button(role: .destructive) {
                    // Preserve any collection rules — they survive Clear All.
                    // Only rule-based (non-collection) filters are cleared.
                    let collectionRules = expression.groups
                        .flatMap(\.rules)
                        .filter { $0.field == .collection }
                    if collectionRules.isEmpty {
                        expression = FilterExpression()
                    } else {
                        var fresh = FilterExpression()
                        fresh.groups[0].rules = collectionRules
                        expression = fresh
                    }
                    onClear()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(.red)
                .disabled(expression.isEmpty)

                Spacer()

                Button("+ Add Group") {
                    withAnimation { expression.groups.append(FilterGroup()) }
                }
                .buttonStyle(.borderless)

                Button("Apply") { onApply(); dismiss() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!expression.hasCompleteRules)
            }
            .padding(20)
        }
        .frame(width: 540)
    }
}

// MARK: - GroupSection

private struct GroupSection: View {
    @Binding var group: FilterGroup
    let showGroupLabel: Bool
    let groupIndex: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Group header
            HStack {
                if showGroupLabel {
                    Text("Group \(groupIndex + 1)")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }

                // Within-group conjunction
                if group.rules.count >= 2 {
                    Picker("", selection: $group.conjunction) {
                        Text("ALL (AND)").tag(FilterConjunction.and)
                        Text("ANY (OR)").tag(FilterConjunction.or)
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .font(.caption)
                }

                Spacer()

                if showGroupLabel {
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless).font(.caption)
                }

                Button("+ Rule") {
                    withAnimation {
                        group.rules.append(FilterRule(field: .tag, op: .equals, value: ""))
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 20).padding(.top, 10)

            // Rules
            if group.rules.isEmpty {
                Text("No rules — tap + Rule to add one.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            } else {
                ForEach($group.rules) { $rule in
                    FilterRuleRow(rule: $rule) {
                        withAnimation { group.rules.removeAll { $0.id == rule.id } }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

// MARK: - FilterRuleRow

struct FilterRuleRow: View {
    @Binding var rule: FilterRule
    let onDelete: () -> Void

    @Environment(LibrarySession.self) private var session
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var collections: [CollectionRow] = []

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $rule.field) {
                ForEach(visibleFields) { f in Text(f.label).tag(f) }
            }
            .labelsHidden().frame(width: 120)
            .onChange(of: rule.field) {
                if !rule.availableOperators.contains(rule.op) {
                    rule.op = rule.availableOperators[0]
                }
            }

            if rule.field != .isLiked {
                Picker("", selection: $rule.op) {
                    ForEach(rule.availableOperators) { op in Text(op.label).tag(op) }
                }
                .labelsHidden().frame(width: 150)
            }

            valueInput

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task {
            collections = (try? await session.collectionStore?.collections()) ?? []
        }
    }

    @ViewBuilder
    private var valueInput: some View {
        switch rule.field {
        case .isLiked:
            Text("is liked").font(.callout).foregroundStyle(.secondary); Spacer()
        case .collection:
            Picker("", selection: $rule.value) {
                Text("— pick —").tag("")
                ForEach(visibleCollections) { col in
                    Text(col.name).tag(col.name)
                }
            }.labelsHidden().frame(maxWidth: .infinity)
        case .status:
            Picker("", selection: $rule.value) {
                Text("— pick —").tag("")
                ForEach(AO3CompletionStatus.allCases) { status in
                    Text(status.rawValue).tag(status.rawValue)
                }
            }.labelsHidden().frame(maxWidth: .infinity)
        case .rating:
            Picker("", selection: $rule.value) {
                Text("— pick —").tag("")
                // Display in hierarchy order: General (lowest) → Explicit (highest)
                // Not Rated sits outside the scale and is shown last.
                let orderedRatings: [AO3Rating] = [
                    .generalAudiences, .teenAndUp, .mature, .explicit, .notRated
                ]
                ForEach(orderedRatings, id: \.rawValue) { r in
                    HStack {
                        Text(r.rawValue)
                        if let level = r.level {
                            Text("(\(["", "low", "", "", "high"][min(level, 4)]))")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .tag(r.rawValue)
                }
            }.labelsHidden().frame(maxWidth: .infinity)
        case .warning:
            Picker("", selection: $rule.value) {
                Text("— pick —").tag("")
                ForEach(AO3Warning.allCases, id: \.rawValue) { w in Text(w.rawValue).tag(w.rawValue) }
            }.labelsHidden().frame(maxWidth: .infinity)
        case .category:
            Picker("", selection: $rule.value) {
                Text("— pick —").tag("")
                ForEach(AO3Category.allCases, id: \.rawValue) { c in Text(c.rawValue).tag(c.rawValue) }
            }.labelsHidden().frame(maxWidth: .infinity)
        case .wordCountGT, .wordCountLT, .kudosGT, .kudosLT:
            TextField("Number", text: $rule.value)
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        default:
            TextField(placeholder, text: $rule.value)
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        }
    }

    private var visibleCollections: [CollectionRow] {
        collections.filter { col in
            col.id != SystemCollectionID.skipped || prefs.showSkippedCollection
        }
    }

    private var visibleFields: [FilterField] {
        return FilterField.visibleCases
    }

    private var placeholder: String {
        switch rule.field {
        case .tag:        return "Tag name…"
        case .authorName: return "Author name…"
        case .series:     return "Series name…"
        case .comment:    return "Text in description…"
        default:          return "Value…"
        }
    }
}
