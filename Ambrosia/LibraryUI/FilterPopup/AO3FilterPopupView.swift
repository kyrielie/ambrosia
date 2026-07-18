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

    @State private var facets: [AO3FacetField: [(name: String, count: Int)]] = [:]
    @State private var ratingFacets: [(name: String, count: Int)] = []

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
                    facets: facets, ratingFacets: ratingFacets, onToggle: refreshFacets
                )

                Divider()

                FilterDirectionSection(
                    title: "Exclude", direction: .exclude, state: state,
                    facets: facets, ratingFacets: ratingFacets, onToggle: refreshFacets
                )

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("More Options").font(.headline)
                    TriStateSection(title: "Crossovers", selection: $state.crossoverState, onChange: refreshFacets)
                    TriStateSection(title: "Completion Status", selection: $state.completionState, onChange: refreshFacets)
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
        refreshFacets()
    }

    private func refreshFacets() {
        Task {
            var newFacets: [AO3FacetField: [(name: String, count: Int)]] = [:]
            for field in AO3FacetField.allCases {
                let ids = await facetController.scopedIDs(ignoring: field, state: state)
                let raw = await facetController.metaDB.topFacets(for: field, scopedTo: ids)
                newFacets[field] = await facetController.metaDB.canonicalize(raw)
            }
            facets = newFacets

            let ratingIDs = await facetController.scopedIDsForRating(state: state)
            ratingFacets = await facetController.metaDB.topRatingFacets(scopedTo: ratingIDs)
        }
    }

    private func apply() {
        toolbarState.filterExpression = state.buildExpression()
        toolbarState.sortField = state.sortField
        toolbarState.ascending = state.ascending
    }
}

// MARK: - FilterDirection

enum FilterDirection {
    case include
    case exclude
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
    let onToggle: () -> Void

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
            DirectionalTagFacetSection(field: .fandom, direction: direction, entries: facets[.fandom] ?? [], state: state, onToggle: onToggle)
            DirectionalTagFacetSection(field: .character, direction: direction, entries: facets[.character] ?? [], state: state, onToggle: onToggle)
            DirectionalTagFacetSection(field: .relationship, direction: direction, entries: facets[.relationship] ?? [], state: state, onToggle: onToggle)
            DirectionalTagFacetSection(field: .freeform, direction: direction, entries: facets[.freeform] ?? [], state: state, onToggle: onToggle)
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
            if isOn { state.includedWarnings.insert(w); state.excludedWarnings.remove(w) }
            else { state.includedWarnings.remove(w) }
        case .exclude:
            if isOn { state.excludedWarnings.insert(w); state.includedWarnings.remove(w) }
            else { state.excludedWarnings.remove(w) }
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
            if isOn { state.includedCategories.insert(c); state.excludedCategories.remove(c) }
            else { state.includedCategories.remove(c) }
        case .exclude:
            if isOn { state.excludedCategories.insert(c); state.includedCategories.remove(c) }
            else { state.excludedCategories.remove(c) }
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
    @Bindable var state: AO3FilterPopupState
    let onToggle: () -> Void
    @State private var isExpanded = false

    private var stringField: AO3FilterPopupState.StringTagField {
        switch field {
        case .fandom: return .fandom
        case .relationship: return .relationship
        case .character: return .character
        case .freeform: return .freeform
        case .warning, .category: return .freeform // unused here; warning/category use DirectionalEnumFacetSection
        }
    }

    private func isOn(_ value: String) -> Bool {
        direction == .include ? state.isIncluded(value, field: stringField) : state.isExcluded(value, field: stringField)
    }

    private func toggle(_ value: String) {
        if direction == .include { state.toggleInclude(value, field: stringField) }
        else { state.toggleExclude(value, field: stringField) }
        onToggle()
    }

    private var hasActiveSelection: Bool { entries.contains { isOn($0.name) } }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.name) { entry in
                    Toggle(isOn: Binding(get: { isOn(entry.name) }, set: { _ in toggle(entry.name) })) {
                        Text("\(entry.name) (\(entry.count))")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 4)
        } label: {
            Text(field.sectionLabel)
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
        DisclosureGroup(isExpanded: $isExpanded) {
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
            .padding(.leading, 4)
        } label: {
            Text(title)
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
        DisclosureGroup(isExpanded: $isExpanded) {
            switch direction {
            case .include:
                Picker("Rating", selection: includeSelection) {
                    Text("Any").tag(AO3Rating?.none)
                    ForEach(AO3Rating.allCases, id: \.self) { rating in
                        Text("\(rating.rawValue) (\(count(for: rating)))").tag(AO3Rating?.some(rating))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            case .exclude:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AO3Rating.allCases, id: \.self) { rating in
                        Toggle(isOn: excludeBinding(rating)) {
                            Text("\(rating.rawValue) (\(count(for: rating)))")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
            }
        } label: {
            Text("Rating")
        }
        .onAppear {
            isExpanded = direction == .include ? state.includedRating != nil : !state.excludedRatings.isEmpty
        }
    }

    private var includeSelection: Binding<AO3Rating?> {
        Binding(
            get: { state.includedRating },
            set: { newValue in
                state.includedRating = newValue
                if let newValue { state.excludedRatings.remove(newValue) }
                onToggle()
            }
        )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Picker(title, selection: Binding(get: { selection }, set: { selection = $0; onChange() })) {
                Text("Include all").tag(AO3FilterPopupState.TriState.any)
                Text("Exclude").tag(AO3FilterPopupState.TriState.excludeOnly)
                Text("Only").tag(AO3FilterPopupState.TriState.includeOnly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(.vertical, 2)
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
