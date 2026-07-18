import SwiftUI
import SwiftData

// MARK: - FilterDrawerView

struct FilterDrawerView: View {
    @Binding var expression: FilterExpression
    var onApply: () -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    if reduceMotion {
                        expression.groups.append(FilterGroup())
                    } else {
                        withAnimation { expression.groups.append(FilterGroup()) }
                    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    if reduceMotion {
                        group.rules.append(FilterRule(field: .tag, op: .equals, value: ""))
                    } else {
                        withAnimation {
                            group.rules.append(FilterRule(field: .tag, op: .equals, value: ""))
                        }
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
                // CRASH FIX: ForEach($group.rules) creates Binding<FilterRule>
            // via array index subscript.  When the delete button is clicked,
            // AppKit resigns the active NSTextField as part of mouse handling,
            // which causes SwiftUI's PlatformTextFieldCoordinator to enqueue
            // controlTextDidEndEditing.  That action is dispatched in the same
            // button-action cycle after onDelete() has already removed the
            // element — the index is stale and Swift traps.
            //
            // Fix: iterate over value-type snapshots (not $bindings) and
            // construct each rule's Binding via UUID lookup instead of index
            // subscript.  UUID lookup never goes out of bounds — if the rule
            // has been removed, the Binding's getter/setter simply no-ops.
            ForEach(group.rules) { rule in
                    FilterRuleRow(rule: ruleBinding(for: rule.id)) {
                        if reduceMotion {
                            group.rules.removeAll { $0.id == rule.id }
                        } else {
                            withAnimation { group.rules.removeAll { $0.id == rule.id } }
                        }
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

    /// Returns a Binding<FilterRule> that reads and writes by UUID, never
    /// by array index.  Safe to use across mutations — if the rule has been
    /// removed by the time the Binding is read (e.g. from a deferred
    /// controlTextDidEndEditing), the getter returns a default rule and
    /// the setter is a no-op, avoiding any out-of-bounds trap.
    private func ruleBinding(for id: UUID) -> Binding<FilterRule> {
        Binding<FilterRule>(
            get: {
                group.rules.first { $0.id == id } ?? FilterRule()
            },
            set: { newValue in
                if let idx = group.rules.firstIndex(where: { $0.id == id }) {
                    group.rules[idx] = newValue
                }
            }
        )
    }
}

// MARK: - FilterRuleRow

struct FilterRuleRow: View {
    @Binding var rule: FilterRule
    let onDelete: () -> Void

    @Environment(LibrarySession.self) private var session
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var collections: [CollectionRow] = []
    @State private var collectionSearchText = ""
    @State private var showCollectionPicker = false
    @FocusState private var collectionSearchFocused: Bool
    /// Captured by WindowAccessorView embedded in the row body.
    /// Used by the delete closure to resign first-responder on the
    /// correct window — NSApp.keyWindow is unreliable inside sheets.
    @State private var rowWindow: NSWindow? = nil

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

            Picker("", selection: operatorBinding) {
                ForEach(rule.availableOperators) { op in Text(op.label).tag(op) }
            }
            .labelsHidden().frame(width: 150)

            valueInput

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // WindowAccessorView captures the NSWindow that hosts this row.
        // This is necessary because FilterDrawerView is presented as a
        // .sheet(), which runs in a child NSWindow separate from the main
        // window.  NSApp.keyWindow may point to the wrong window.
        .background(WindowAccessorView { win in
            if rowWindow !== win {
                #if DEBUG
                print("[FilterRuleRow] window captured: \(win?.title ?? "nil") (\(String(describing: win)))")
                #endif
                rowWindow = win
            }
        })
        .onAppear {
            normalizeOperator()
        }
        .task {
            collections = (try? await session.collectionStore?.collections()) ?? []
        }
    }

    @ViewBuilder
    private var valueInput: some View {
        switch rule.field {
        case .collection:
            collectionSearchField
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
        case .crossover:                                        // §6
            Text("crossover").font(.callout).foregroundStyle(.secondary); Spacer()
        default:
            // FilterValueTextField provides live autocomplete for .tag,
            // .authorName, and .title via CalibreLibrary suggestion queries.
            // Fields that don't support autocomplete (.series, .comment,
            // .fulltext, …) fall through to the plain variant inside the
            // component — zero overhead, no behaviour change.
            FilterValueTextField(
                placeholder: placeholder,
                text: $rule.value,
                field: rule.field,
                library: session.library
            ) { selected in
                rule.value = selected
            }
        }
    }

    private var visibleCollections: [CollectionRow] {
        collections.filter { col in
            col.id != SystemCollectionID.skipped || prefs.showSkippedCollection
        }
    }

    private var filteredCollections: [CollectionRow] {
        let query = collectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleCollections }
        return visibleCollections.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var collectionSearchField: some View {
        Button {
            showCollectionPicker = true
        } label: {
            HStack {
                Text(rule.value.isEmpty ? "Pick collection" : rule.value)
                    .lineLimit(1)
                    .foregroundStyle(rule.value.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCollectionPicker, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search collections", text: $collectionSearchText)
                        .textFieldStyle(.plain)
                        .focused($collectionSearchFocused)
                    if !collectionSearchText.isEmpty {
                        Button {
                            collectionSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        collectionChoice(title: "— pick —", isSelected: rule.value.isEmpty) {
                            rule.value = ""
                            closeCollectionPicker()
                        }
                        ForEach(filteredCollections) { col in
                            collectionChoice(title: col.name, isSelected: rule.value == col.name) {
                                rule.value = col.name
                                closeCollectionPicker()
                            }
                        }
                        if filteredCollections.isEmpty {
                            Text("No collections")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .frame(width: 260)
            .onAppear {
                DispatchQueue.main.async {
                    collectionSearchFocused = true
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func collectionChoice(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func closeCollectionPicker() {
        collectionSearchText = ""
        showCollectionPicker = false
    }

    private func normalizeOperator() {
        if !rule.availableOperators.contains(rule.op) {
            rule.op = rule.availableOperators[0]
        }
    }

    private var operatorBinding: Binding<FilterOperator> {
        Binding(
            get: {
                rule.availableOperators.contains(rule.op) ? rule.op : rule.availableOperators[0]
            },
            set: { rule.op = $0 }
        )
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
        case .fulltext:   return "Text in book…"
        default:          return "Value…"
        }
    }
}

// MARK: - WindowAccessorView
//
// Embeds a zero-size NSView in the SwiftUI hierarchy and calls back with the
// NSWindow it belongs to whenever it changes.  Used to capture the exact
// NSWindow hosting a SwiftUI view — necessary when the view lives inside a
// .sheet(), which AppKit renders in a child window separate from the main window.

private struct WindowAccessorView: NSViewRepresentable {

    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // updateNSView is called after the view is added to the window.
        // Schedule on the next run loop to ensure nsView.window is populated.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            onWindow(nsView.window)
        }
    }
}
