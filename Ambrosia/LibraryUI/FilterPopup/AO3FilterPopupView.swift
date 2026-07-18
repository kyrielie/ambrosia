import SwiftUI

// MARK: - AO3FilterPopupView

struct AO3FilterPopupView: View {
    @Bindable var state: AO3FilterPopupState
    let toolbarState: LibraryToolbarState
    let facetController: AO3FilterFacetController

    @State private var facets: [AO3FacetField: [(name: String, count: Int)]] = [:]
    @State private var ratingFacets: [(name: String, count: Int)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([AO3FacetField.fandom, .relationship, .character, .freeform], id: \.self) { field in
                    TagFacetSection(field: field, entries: facets[field] ?? [], state: state, onToggle: refreshFacets)
                }
                RatingFacetSection(entries: ratingFacets, state: state, onToggle: refreshFacets)
                EnumFacetSection(
                    title: AO3FacetField.warning.sectionLabel,
                    allCases: AO3Warning.allCases,
                    included: $state.includedWarnings,
                    excluded: $state.excludedWarnings,
                    onToggle: refreshFacets
                )
                EnumFacetSection(
                    title: AO3FacetField.category.sectionLabel,
                    allCases: AO3Category.allCases,
                    included: $state.includedCategories,
                    excluded: $state.excludedCategories,
                    onToggle: refreshFacets
                )
                TriStateSection(title: "Crossovers", selection: $state.crossoverState, onChange: refreshFacets)
                TriStateSection(title: "Completion Status", selection: $state.completionState, onChange: refreshFacets)
                Divider().padding(.vertical, 8)
                SortSection(sortField: $state.sortField, ascending: $state.ascending)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reset") { resetSelections() }
                Spacer()
                Button("Sort and Filter") { apply() } // AO3's own button label, reused deliberately
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
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
            for field in [AO3FacetField.fandom, .relationship, .character, .freeform, .warning, .category] {
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

// MARK: - TagFacetSection
//
// Reproduces AO3's accordion behavior (`filters.js`'s setupFilterToggles`/
// `showFilters`): collapsed by default, auto-expanded only if this section
// already has an active selection when the popup opens.

struct TagFacetSection: View {
    let field: AO3FacetField
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
        case .warning, .category: return .freeform // unused: warning/category use EnumFacetSection instead
        }
    }

    private var hasActiveSelection: Bool {
        entries.contains { state.isIncluded($0.name, field: stringField) || state.isExcluded($0.name, field: stringField) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(entries, id: \.name) { entry in
                HStack {
                    Toggle("Include", isOn: includeBinding(entry.name))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Toggle("Exclude", isOn: excludeBinding(entry.name))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Text("\(entry.name) (\(entry.count))")
                }
            }
        } label: {
            Text(field.sectionLabel)
        }
        .onAppear { isExpanded = hasActiveSelection }
    }

    private func includeBinding(_ value: String) -> Binding<Bool> {
        Binding(
            get: { state.isIncluded(value, field: stringField) },
            set: { _ in
                state.toggleInclude(value, field: stringField)
                onToggle()
            }
        )
    }

    private func excludeBinding(_ value: String) -> Binding<Bool> {
        Binding(
            get: { state.isExcluded(value, field: stringField) },
            set: { _ in
                state.toggleExclude(value, field: stringField)
                onToggle()
            }
        )
    }
}

// MARK: - EnumFacetSection
//
// Same include/exclude checkbox shape as TagFacetSection, but for
// Warning/Category, which use AO3's fixed vocabularies (`AO3Warning`/
// `AO3Category`) instead of free-form facet strings. Counts still come from
// the live facet query — a value with 0 matching books in the current scope
// still renders, at count 0, exactly like AO3 re-injects excluded-tag facets
// at count 0 rather than hiding them.

struct EnumFacetSection<T: RawRepresentable & CaseIterable & Hashable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let title: String
    let allCases: T.AllCases
    @Binding var included: Set<T>
    @Binding var excluded: Set<T>
    let onToggle: () -> Void
    @State private var isExpanded = false

    private var hasActiveSelection: Bool { !included.isEmpty || !excluded.isEmpty }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(Array(allCases), id: \.self) { value in
                HStack {
                    Toggle("Include", isOn: includeBinding(value)).toggleStyle(.checkbox).labelsHidden()
                    Toggle("Exclude", isOn: excludeBinding(value)).toggleStyle(.checkbox).labelsHidden()
                    Text(value.rawValue)
                }
            }
        } label: {
            Text(title)
        }
        .onAppear { isExpanded = hasActiveSelection }
    }

    private func includeBinding(_ value: T) -> Binding<Bool> {
        Binding(
            get: { included.contains(value) },
            set: { isOn in
                if isOn { included.insert(value); excluded.remove(value) } else { included.remove(value) }
                onToggle()
            }
        )
    }

    private func excludeBinding(_ value: T) -> Binding<Bool> {
        Binding(
            get: { excluded.contains(value) },
            set: { isOn in
                if isOn { excluded.insert(value); included.remove(value) } else { excluded.remove(value) }
                onToggle()
            }
        )
    }
}

// MARK: - RatingFacetSection
//
// Include side is a radio group (AO3 only uses a radio when there's more
// than one rating option to include); exclude side is independent checkboxes
// per rating, matching AO3's own asymmetry.

struct RatingFacetSection: View {
    let entries: [(name: String, count: Int)]
    @Bindable var state: AO3FilterPopupState
    let onToggle: () -> Void
    @State private var isExpanded = false

    private func count(for rating: AO3Rating) -> Int {
        entries.first { $0.name == rating.rawValue }?.count ?? 0
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Picker("Include", selection: includeSelection) {
                Text("Any").tag(AO3Rating?.none)
                ForEach(AO3Rating.allCases, id: \.self) { rating in
                    Text("\(rating.rawValue) (\(count(for: rating)))").tag(AO3Rating?.some(rating))
                }
            }
            .pickerStyle(.radioGroup)

            ForEach(AO3Rating.allCases, id: \.self) { rating in
                Toggle("Exclude \(rating.rawValue) (\(count(for: rating)))", isOn: excludeBinding(rating))
                    .toggleStyle(.checkbox)
            }
        } label: {
            Text("Rating")
        }
        .onAppear { isExpanded = state.includedRating != nil || !state.excludedRatings.isEmpty }
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
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Picker(title, selection: Binding(get: { selection }, set: { selection = $0; onChange() })) {
                Text("Include all").tag(AO3FilterPopupState.TriState.any)
                Text("Exclude").tag(AO3FilterPopupState.TriState.excludeOnly)
                Text("Only").tag(AO3FilterPopupState.TriState.includeOnly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SortSection

struct SortSection: View {
    @Binding var sortField: SortField
    @Binding var ascending: Bool

    var body: some View {
        HStack {
            Picker("Sort by", selection: $sortField) {
                ForEach(SortField.allCases) { field in
                    Text(field.rawValue.capitalized).tag(field)
                }
            }
            Toggle("Ascending", isOn: $ascending)
        }
        .padding(.vertical, 4)
    }
}
