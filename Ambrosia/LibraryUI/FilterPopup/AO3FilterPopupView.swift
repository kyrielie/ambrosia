import SwiftUI

// MARK: - AO3FilterPopupView
//
// Reproduces AO3's own `_filters.html.erb` layout, not just its individual
// controls:
//   - The submit button ("Sort and Filter") and the "Sort by" dropdown are
//     the first two `<dt>/<dd>` pairs in the form -- both live at the top of
//     this view too, not in a bottom bar.
//   - Include and Exclude are two entirely separate top-level sections
//     (`%w(include exclude).each do |filter_action|`), each iterating all
//     seven tag types in AO3's own order (rating, archive_warning, category,
//     fandom, character, relationship, freeform) and rendering ONE checkbox
//     per tag per section -- not a single row with paired include/exclude
//     toggles.
//   - Within each accordion's `<ul><li>`, every row is a single checkbox
//     label, left-aligned, with no independent spacing per row.

struct AO3FilterPopupView: View {
    @Bindable var state: AO3FilterPopupState
    let toolbarState: LibraryToolbarState
    let facetController: AO3FilterFacetController
    /// Snapshot of `LibrarySession.membershipVersion` at the time this view
    /// was installed. Passed straight through to
    /// `AO3FilterFacetController.topFacets`/`topRatingFacets` as the cache
    /// key for the whole-library facet baseline -- a plain value, not
    /// something this view needs to observe for live updates, since a
    /// mid-session membership change is meant to invalidate the *next*
    /// popup open/reopen (a fresh `AO3FilterPopupWindowController` rebuild),
    /// not repaint the popup that's already on screen.
    let membershipVersion: Int
    // §9: Invoked after apply() writes to toolbarState, so the owning
    // AO3FilterPopupWindowController can resync state.capturedDigest and
    // rebuild facetController.baseIDs against the newly-applied expression.
    // Without this, apply() left both stale: baseIDs kept reflecting the
    // pre-Apply toolbar filter (so any further toggle's facet counts stopped
    // matching the filter actually in effect), and capturedDigest kept its
    // pre-Apply value, so the *next* reopen of this same popup saw its own
    // just-applied expression as an external change and silently discarded
    // the checkboxes that produced it. See fix plan §3b.
    var onApply: () -> Void = {}

    @State private var facets: [AO3FacetField: [(name: String, count: Int)]] = [:]
    @State private var ratingFacets: [(name: String, count: Int)] = []
    @State private var facetRefreshTask: Task<Void, Never>?
    @State private var facetLimits: [AO3FacetField: Int] = [:]

    private static let facetPageSize = 10

    private func limit(for field: AO3FacetField) -> Int {
        facetLimits[field] ?? Self.facetPageSize
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Submit + sort, in that order, matching AO3's own <dl> order.
                HStack {
                    Button("Sort and Filter") { apply() }
                        .keyboardShortcut(.defaultAction)
                    Button("Reset") { resetSelections() }
                    Spacer()
                }
                SortSection(sortField: $state.sortField, ascending: $state.ascending)

                Divider()

                FilterDirectionSection(
                    title: "Include", direction: .include, state: state,
                    facets: facets, ratingFacets: ratingFacets, facetLimits: facetLimits,
                    onToggle: refreshFacets, onLoadMore: loadMoreFacets
                )

                Divider()

                FilterDirectionSection(
                    title: "Exclude", direction: .exclude, state: state,
                    facets: facets, ratingFacets: ratingFacets, facetLimits: facetLimits,
                    onToggle: refreshFacets, onLoadMore: loadMoreFacets
                )

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("More Options").font(.headline)
                    TriStateSection(
                        title: "Crossovers", selection: $state.crossoverState, onChange: refreshFacets,
                        anyLabel: "Include crossovers", excludeLabel: "Exclude crossovers", includeOnlyLabel: "Show only crossovers"
                    )
                    TriStateSection(
                        title: "Completion Status", selection: $state.completionState, onChange: refreshFacets,
                        anyLabel: "All works", excludeLabel: "Works in progress only", includeOnlyLabel: "Complete works only"
                    )
                }
            }
            .padding()
        }
        .task { refreshFacets() }
        .frame(minWidth: 360, minHeight: 400)
    }

    private func resetSelections() {
        state.includedFandoms = []
        state.excludedFandoms = []
        state.includedRelationships = []
        state.excludedRelationships = []
        state.includedCharacters = []
        state.excludedCharacters = []
        state.includedFreeforms = []
        state.excludedFreeforms = []
        state.includedWarnings = []
        state.excludedWarnings = []
        state.includedCategories = []
        state.excludedCategories = []
        state.includedRating = nil
        state.excludedRatings = []
        state.crossoverState = .any
        state.completionState = .any
        facetLimits = [:]
        refreshFacets()
    }

    // §9: Previously ran one full matchingIDs pass per facet field, serially,
    // on every checkbox toggle — 7 sequential round trips (6 tag-shaped
    // AO3FacetField cases plus rating) per toggle, per filterlogs.txt's
    // near-identical consecutive matchingIDs.start/end pairs. Each field's
    // scopedIDs call only reads `state`/`baseIDs`, both immutable for the
    // duration of one refreshFacets() invocation, so the calls are
    // independent and can run concurrently. CalibreLibrary/AmbrosiaMetaDB are
    // both actors, so this overlaps wait time across fields rather than
    // truly parallelizing SQLite execution — still a real win over the fully
    // serial await chain. See fix plan §2.
    //
    // §10: Also routes through AO3FilterFacetController.topFacets/
    // topRatingFacets rather than calling AmbrosiaMetaDB.topFacets(scopedTo:)
    // directly. With no active drawer/search filter and no popup selections
    // -- the single most common way this popup gets opened -- the old direct
    // call passed the ENTIRE library's ID list as one bound parameter per ID,
    // silently failing past SQLite's default 999-parameter limit (the
    // `try?` in AmbrosiaMetaDB.topFacets swallowed the error and returned
    // `[]`). The controller now detects that "wholly unconstrained" case and
    // uses an ID-list-free query instead, cached per membershipVersion.
    private func refreshFacets() {
        facetRefreshTask?.cancel()
        facetRefreshTask = Task {
            async let ratingFacetsTask = facetController.topRatingFacets(state: state, membershipVersion: membershipVersion)

            let newFacets: [AO3FacetField: [(name: String, count: Int)]] =
                await withTaskGroup(of: (AO3FacetField, [(name: String, count: Int)]).self) { group in
                    for field in AO3FacetField.allCases {
                        group.addTask {
                            let entries = await facetController.topFacets(
                                for: field, state: state, limit: limit(for: field), membershipVersion: membershipVersion
                            )
                            return (field, entries)
                        }
                    }
                    var result: [AO3FacetField: [(name: String, count: Int)]] = [:]
                    for await (field, entries) in group {
                        result[field] = entries
                    }
                    return result
                }

            guard !Task.isCancelled else { return }
            facets = newFacets

            let ratingFacetsResult = await ratingFacetsTask
            guard !Task.isCancelled else { return }
            ratingFacets = ratingFacetsResult
        }
    }

    /// "Load more" for a single tag facet type: bumps that field's own limit
    /// and refetches just that field, rather than re-running every field's
    /// `matchingIDs`/`topFacets` query like a full `refreshFacets()` would.
    private func loadMoreFacets(_ field: AO3FacetField) {
        facetLimits[field] = limit(for: field) + Self.facetPageSize
        Task {
            let entries = await facetController.topFacets(
                for: field, state: state, limit: limit(for: field), membershipVersion: membershipVersion
            )
            guard !Task.isCancelled else { return }
            facets[field] = entries
        }
    }

    private func apply() {
        toolbarState.filterExpression = state.buildExpression()
        toolbarState.sortField = state.sortField
        toolbarState.ascending = state.ascending
        onApply()
    }
}

// MARK: - FilterDirection

enum FilterDirection {
    case include
    case exclude
}

// MARK: - AccordionSection
//
// A DisclosureGroup replacement whose ENTIRE header row is the tap target
// (AO3's own JS toggles the drawer on a click anywhere in the `<h5>` row,
// not just its text) and whose content sits flush against the leading edge
// -- no indentation, matching AO3's own unindented `<ul>` list.

struct AccordionSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 10)
                    Text(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - RadioRow
//
// A radio-button row whose entire horizontal area is clickable and which
// sits flush left, unlike `Picker(.radioGroup)`, which indents each option.

struct RadioRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                Text(label)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FilterDirectionSection
//
// One whole top-level "Include" or "Exclude" block: every tag type's
// accordion, in AO3's own order (rating, archive_warning, category, fandom,
// character, relationship, freeform).

struct FilterDirectionSection: View {
    let title: String
    let direction: FilterDirection
    @Bindable var state: AO3FilterPopupState
    let facets: [AO3FacetField: [(name: String, count: Int)]]
    let ratingFacets: [(name: String, count: Int)]
    let facetLimits: [AO3FacetField: Int]
    let onToggle: () -> Void
    let onLoadMore: (AO3FacetField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold())

            RatingDirectionalSection(direction: direction, entries: ratingFacets, state: state, onToggle: onToggle)
            DirectionalEnumFacetSection(
                title: AO3FacetField.warning.sectionLabel, direction: direction, allCases: AO3Warning.allCases,
                selected: warningBinding, counts: warningCount, onSelect: warningSelect
            )
            DirectionalEnumFacetSection(
                title: AO3FacetField.category.sectionLabel, direction: direction, allCases: AO3Category.allCases,
                selected: categoryBinding, counts: categoryCount, onSelect: categorySelect
            )
            DirectionalTagFacetSection(
                field: .fandom, direction: direction, entries: facets[.fandom] ?? [],
                limit: facetLimits[.fandom] ?? 10, state: state, onToggle: onToggle,
                onLoadMore: { onLoadMore(.fandom) }
            )
            DirectionalTagFacetSection(
                field: .character, direction: direction, entries: facets[.character] ?? [],
                limit: facetLimits[.character] ?? 10, state: state, onToggle: onToggle,
                onLoadMore: { onLoadMore(.character) }
            )
            DirectionalTagFacetSection(
                field: .relationship, direction: direction, entries: facets[.relationship] ?? [],
                limit: facetLimits[.relationship] ?? 10, state: state, onToggle: onToggle,
                onLoadMore: { onLoadMore(.relationship) }
            )
            DirectionalTagFacetSection(
                field: .freeform, direction: direction, entries: facets[.freeform] ?? [],
                limit: facetLimits[.freeform] ?? 10, state: state, onToggle: onToggle,
                onLoadMore: { onLoadMore(.freeform) }
            )
            DirectionalTagFacetSection(
                field: .author, direction: direction, entries: facets[.author] ?? [],
                limit: facetLimits[.author] ?? 10, state: state, onToggle: onToggle,
                onLoadMore: { onLoadMore(.author) }
            )
        }
    }

    // MARK: Warning/Category plumbing (per-direction bindings into the shared include/exclude sets)

    private var warningBinding: Set<AO3Warning> {
        direction == .include ? state.includedWarnings : state.excludedWarnings
    }
    private func warningCount(_ w: AO3Warning) -> Int {
        (facets[.warning] ?? []).first { $0.name == w.rawValue }?.count ?? 0
    }
    private func warningSelect(_ w: AO3Warning, _ isOn: Bool) {
        switch direction {
        case .include:
            if isOn { state.includedWarnings.insert(w); state.excludedWarnings.remove(w) } else { state.includedWarnings.remove(w) }
        case .exclude:
            if isOn { state.excludedWarnings.insert(w); state.includedWarnings.remove(w) } else { state.excludedWarnings.remove(w) }
        }
        onToggle()
    }

    private var categoryBinding: Set<AO3Category> {
        direction == .include ? state.includedCategories : state.excludedCategories
    }
    private func categoryCount(_ c: AO3Category) -> Int {
        (facets[.category] ?? []).first { $0.name == c.rawValue }?.count ?? 0
    }
    private func categorySelect(_ c: AO3Category, _ isOn: Bool) {
        switch direction {
        case .include:
            if isOn { state.includedCategories.insert(c); state.excludedCategories.remove(c) } else { state.includedCategories.remove(c) }
        case .exclude:
            if isOn { state.excludedCategories.insert(c); state.includedCategories.remove(c) } else { state.excludedCategories.remove(c) }
        }
        onToggle()
    }
}

// MARK: - DirectionalTagFacetSection
//
// One tag type's accordion within a single Include OR Exclude section --
// one checkbox per tag, left-aligned in a plain leading VStack (no HStack
// spacers, no per-row independent widths).

struct DirectionalTagFacetSection: View {
    let field: AO3FacetField
    let direction: FilterDirection
    let entries: [(name: String, count: Int)]
    let limit: Int
    @Bindable var state: AO3FilterPopupState
    let onToggle: () -> Void
    let onLoadMore: () -> Void
    @State private var isExpanded = false

    private var stringField: AO3FilterPopupState.StringTagField {
        switch field {
        case .fandom: return .fandom
        case .relationship: return .relationship
        case .character: return .character
        case .freeform: return .freeform
        case .author: return .author
        case .warning, .category: return .freeform // unused here; warning/category use DirectionalEnumFacetSection
        }
    }

    private func isOn(_ value: String) -> Bool {
        direction == .include ? state.isIncluded(value, field: stringField) : state.isExcluded(value, field: stringField)
    }

    private func toggle(_ value: String) {
        if direction == .include { state.toggleInclude(value, field: stringField) } else { state.toggleExclude(value, field: stringField) }
        onToggle()
    }

    private var hasActiveSelection: Bool { entries.contains { isOn($0.name) } }

    // `entries.count` hit the requested `limit` exactly -- there may be more
    // tags in this scope than we've fetched, so offer another page. If the
    // DB returned fewer rows than asked for, we've already seen every tag.
    private var hasMore: Bool { entries.count >= limit }

    var body: some View {
        AccordionSection(title: field.sectionLabel, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.name) { entry in
                    Toggle(isOn: Binding(get: { isOn(entry.name) }, set: { _ in toggle(entry.name) })) {
                        Text("\(entry.name) (\(entry.count))")
                    }
                    .toggleStyle(.checkbox)
                }
                if hasMore {
                    Button("Load more", action: onLoadMore)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { isExpanded = hasActiveSelection }
    }
}

// MARK: - DirectionalEnumFacetSection
//
// Same shape as DirectionalTagFacetSection, but for a fixed
// `RawRepresentable & CaseIterable` vocabulary (AO3Warning/AO3Category),
// scoped to a single direction's `Set` binding.

struct DirectionalEnumFacetSection<T: RawRepresentable & CaseIterable & Hashable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let title: String
    let direction: FilterDirection
    let allCases: T.AllCases
    let selected: Set<T>
    let counts: (T) -> Int
    let onSelect: (T, Bool) -> Void
    @State private var isExpanded = false

    var body: some View {
        AccordionSection(title: title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(allCases), id: \.self) { value in
                    Toggle(isOn: Binding(
                        get: { selected.contains(value) },
                        set: { isOn in onSelect(value, isOn) }
                    )) {
                        Text("\(value.rawValue) (\(counts(value)))")
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .onAppear { isExpanded = !selected.isEmpty }
    }
}

// MARK: - RatingDirectionalSection
//
// Include side is a radio group (AO3 only uses a radio when there's more
// than one rating option to include); Exclude side is independent checkboxes
// per rating -- matching AO3's own asymmetry, now split across the two
// top-level sections rather than living in one combined row.

struct RatingDirectionalSection: View {
    let direction: FilterDirection
    let entries: [(name: String, count: Int)]
    @Bindable var state: AO3FilterPopupState
    let onToggle: () -> Void
    @State private var isExpanded = false

    private func count(for rating: AO3Rating) -> Int {
        entries.first { $0.name == rating.rawValue }?.count ?? 0
    }

    var body: some View {
        AccordionSection(title: "Rating", isExpanded: $isExpanded) {
            switch direction {
            case .include:
                VStack(alignment: .leading, spacing: 2) {
                    RadioRow(label: "Any", isSelected: state.includedRating == nil) {
                        selectIncluded(nil)
                    }
                    ForEach(AO3Rating.allCases, id: \.self) { rating in
                        RadioRow(label: "\(rating.rawValue) (\(count(for: rating)))", isSelected: state.includedRating == rating) {
                            selectIncluded(rating)
                        }
                    }
                }
            case .exclude:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AO3Rating.allCases, id: \.self) { rating in
                        Toggle(isOn: excludeBinding(rating)) {
                            Text("\(rating.rawValue) (\(count(for: rating)))")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .onAppear {
            isExpanded = direction == .include ? state.includedRating != nil : !state.excludedRatings.isEmpty
        }
    }

    private func selectIncluded(_ newValue: AO3Rating?) {
        state.includedRating = newValue
        if let newValue { state.excludedRatings.remove(newValue) }
        onToggle()
    }

    private func excludeBinding(_ rating: AO3Rating) -> Binding<Bool> {
        Binding(
            get: { state.excludedRatings.contains(rating) },
            set: { isOn in
                if isOn {
                    state.excludedRatings.insert(rating)
                    if state.includedRating == rating { state.includedRating = nil }
                } else {
                    state.excludedRatings.remove(rating)
                }
                onToggle()
            }
        )
    }
}

// MARK: - TriStateSection
//
// A 3-radio-button group directly matching AO3's blank/"F"/"T" markup for
// Crossovers and Completion Status.

struct TriStateSection: View {
    let title: String
    @Binding var selection: AO3FilterPopupState.TriState
    let onChange: () -> Void
    let anyLabel: String
    let excludeLabel: String
    let includeOnlyLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            RadioRow(label: anyLabel, isSelected: selection == .any) { select(.any) }
            RadioRow(label: excludeLabel, isSelected: selection == .excludeOnly) { select(.excludeOnly) }
            RadioRow(label: includeOnlyLabel, isSelected: selection == .includeOnly) { select(.includeOnly) }
        }
        .padding(.vertical, 2)
    }

    private func select(_ newValue: AO3FilterPopupState.TriState) {
        selection = newValue
        onChange()
    }
}

// MARK: - SortSection

struct SortSection: View {
    @Binding var sortField: SortField
    @Binding var ascending: Bool

    var body: some View {
        HStack {
            Text("Sort by")
            Picker("Sort by", selection: $sortField) {
                ForEach(SortField.allCases) { field in
                    Text(field.rawValue.capitalized).tag(field)
                }
            }
            .labelsHidden()
            Toggle("Ascending", isOn: $ascending)
        }
    }
}
