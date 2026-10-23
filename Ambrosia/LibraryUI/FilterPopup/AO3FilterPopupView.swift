import SwiftUI

// MARK: - AO3FilterPopupView
//
// Modernized AO3-style filter popup modeled after Kudos Reader:
//   - Unified form layout (no duplicated Include vs Exclude sections).
//   - 3-state cycling controls for Warnings and Categories (Clear -> Include -> Exclude -> Clear).
//   - `TagSelectField` with flow-layout chips and searchable `TagPickerPopover` with fandom context.
//   - `RatingMatch` (Exact, Rating+, Rating−) and "Include Not Rated".
//   - Word count numeric bounds ("From" / "To").
//   - Debounced facet calculation and bidirectional lossless state synchronization.

struct AO3FilterPopupView: View {
    @Bindable var state: AO3FilterPopupState
    let toolbarState: LibraryToolbarState
    let facetController: AO3FilterFacetController
    let membershipVersion: Int
    var onApply: () -> Void = {}

    @State private var facets: [AO3FacetField: [(name: String, count: Int)]] = [:]
    @State private var ratingFacets: [(name: String, count: Int)] = []
    @State private var facetRefreshTask: Task<Void, Never>?
    @State private var facetLimits: [AO3FacetField: Int] = [:]
    private let facetDebouncer = DebounceTimer(delay: 0.15)

    private static let facetPageSize = 10

    private func limit(for field: AO3FacetField) -> Int {
        facetLimits[field] ?? Self.facetPageSize
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Submit + sort
                HStack {
                    Button("Sort and Filter") { apply() }
                        .keyboardShortcut(.defaultAction)
                    Button("Reset") { resetSelections() }
                    Spacer()
                }
                SortSection(sortField: $state.sortField, ascending: $state.ascending)

                Divider()

                // Ratings with RatingMatch and Unrated toggle
                RatingFacetSection(
                    state: state,
                    ratingFacets: ratingFacets,
                    onToggle: refreshFacets
                )

                Divider()

                // Warnings (3-State Cycling)
                CyclingEnumFacetSection(
                    title: "Archive Warnings",
                    allCases: AO3Warning.allCases,
                    selectionState: { state.selectionState(for: $0) },
                    counts: { warning in
                        (facets[.warning] ?? []).first { $0.name == warning.rawValue }?.count ?? 0
                    },
                    onCycle: { warning in
                        state.cycleWarning(warning)
                        refreshFacets()
                    }
                )

                Divider()

                // Categories (3-State Cycling)
                CyclingEnumFacetSection(
                    title: "Categories",
                    allCases: AO3Category.allCases,
                    selectionState: { state.selectionState(for: $0) },
                    counts: { category in
                        (facets[.category] ?? []).first { $0.name == category.rawValue }?.count ?? 0
                    },
                    onCycle: { category in
                        state.cycleCategory(category)
                        refreshFacets()
                    }
                )

                Divider()

                // Tag Fields (with FlowLayout Chips and Searchable Popover)
                TagSelectField(
                    title: "Fandoms",
                    field: .fandom,
                    tagField: .fandom,
                    state: state,
                    facetController: facetController,
                    onTagChanged: refreshFacets
                )

                TagSelectField(
                    title: "Characters",
                    field: .character,
                    tagField: .character,
                    state: state,
                    facetController: facetController,
                    onTagChanged: refreshFacets
                )

                TagSelectField(
                    title: "Relationships",
                    field: .relationship,
                    tagField: .relationship,
                    state: state,
                    facetController: facetController,
                    onTagChanged: refreshFacets
                )

                TagSelectField(
                    title: "Additional Tags",
                    field: .freeform,
                    tagField: .freeform,
                    state: state,
                    facetController: facetController,
                    onTagChanged: refreshFacets
                )

                TagSelectField(
                    title: "Authors",
                    field: .author,
                    tagField: .author,
                    state: state,
                    facetController: facetController,
                    onTagChanged: refreshFacets
                )

                Divider()

                // Word count bounds
                WordCountSection(state: state, onChange: refreshFacets)

                Divider()

                // More Options (Crossovers & Completion)
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
        state.includedAuthors = []
        state.excludedAuthors = []
        state.includedWarnings = []
        state.excludedWarnings = []
        state.includedCategories = []
        state.excludedCategories = []
        state.includedRating = nil
        state.excludedRatings = []
        state.ratingMatch = .exact
        state.includeNotRated = false
        state.wordsFrom = nil
        state.wordsTo = nil
        state.kudosFrom = nil
        state.kudosTo = nil
        state.crossoverState = .any
        state.completionState = .any
        facetLimits = [:]
        refreshFacets()
    }

    private func refreshFacets() {
        facetRefreshTask?.cancel()
        facetDebouncer.schedule {
            facetRefreshTask = Task { @MainActor in
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
    }

    private func apply() {
        toolbarState.filterExpression = state.buildExpression()
        toolbarState.sortField = state.sortField
        toolbarState.ascending = state.ascending
        onApply()
    }
}

// MARK: - AccordionSection

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
                        .font(.headline)
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

// MARK: - CyclingEnumFacetSection

struct CyclingEnumFacetSection<T: Hashable & RawRepresentable>: View where T.RawValue == String {
    let title: String
    let allCases: [T]
    let selectionState: (T) -> FilterSelectionState
    let counts: (T) -> Int
    let onCycle: (T) -> Void
    @State private var isExpanded = true

    var body: some View {
        AccordionSection(title: title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(allCases, id: \.self) { item in
                    let state = selectionState(item)
                    let cnt = counts(item)
                    Button {
                        onCycle(item)
                    } label: {
                        HStack(spacing: 8) {
                            switch state {
                            case .clear:
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            case .included:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            case .excluded:
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }

                            Text(item.rawValue)
                                .font(.callout)
                                .strikethrough(state == .excluded)
                                .foregroundColor(state == .excluded ? .secondary : (state == .included ? .accentColor : .primary))

                            Spacer()

                            if cnt > 0 {
                                Text("\(cnt)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - RatingFacetSection

struct RatingFacetSection: View {
    @Bindable var state: AO3FilterPopupState
    let ratingFacets: [(name: String, count: Int)]
    let onToggle: () -> Void
    @State private var isExpanded = true

    private func count(for rating: AO3Rating) -> Int {
        ratingFacets.first { $0.name == rating.rawValue }?.count ?? 0
    }

    var body: some View {
        AccordionSection(title: "Rating", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Rating", selection: Binding(
                    get: { state.includedRating },
                    set: { newValue in
                        state.includedRating = newValue
                        if let newValue { state.excludedRatings.remove(newValue) }
                        onToggle()
                    }
                )) {
                    Text("Any Rating").tag(nil as AO3Rating?)
                    ForEach(AO3Rating.allCases, id: \.self) { rating in
                        let cnt = count(for: rating)
                        Text(cnt > 0 ? "\(rating.rawValue) (\(cnt))" : rating.rawValue)
                            .tag(rating as AO3Rating?)
                    }
                }
                .pickerStyle(.menu)

                if state.includedRating != nil {
                    Picker("Match", selection: $state.ratingMatch) {
                        ForEach(RatingMatch.allCases) { match in
                            Text(match.rawValue).tag(match)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.ratingMatch) { _, _ in
                        onToggle()
                    }
                }

                Toggle("Include Not Rated", isOn: $state.includeNotRated)
                    .font(.callout)
                    .onChange(of: state.includeNotRated) { _, _ in
                        onToggle()
                    }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - WordCountSection

struct WordCountSection: View {
    @Bindable var state: AO3FilterPopupState
    let onChange: () -> Void
    @State private var isExpanded = true

    var body: some View {
        AccordionSection(title: "Word Count", isExpanded: $isExpanded) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("From:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Min", value: $state.wordsFrom, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit(onChange)
                }

                HStack(spacing: 4) {
                    Text("To:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Max", value: $state.wordsTo, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit(onChange)
                }

                Spacer()
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - RadioRow

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

// MARK: - TriStateSection

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
