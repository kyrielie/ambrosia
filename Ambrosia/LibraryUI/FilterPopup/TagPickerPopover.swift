import SwiftUI

struct TagPickerPopover: View {
    let title: String
    let field: AO3FacetField
    let tagField: AO3FilterPopupState.StringTagField
    @Bindable var state: AO3FilterPopupState
    let facetController: AO3FilterFacetController
    let onTagChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var searchResults: [(name: String, count: Int)] = []
    @State private var popularResults: [(name: String, count: Int)] = []
    @State private var searchTask: Task<Void, Never>?
    private let debouncer = DebounceTimer(delay: 0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search \(title.lowercased())…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !popularResults.isEmpty && searchText.isEmpty && field != .fandom && !state.includedFandoms.isEmpty {
                        Text("Popular in Selected Fandom")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(popularResults, id: \.name) { item in
                            tagRow(item.name, count: item.count)
                        }

                        Divider()
                            .padding(.vertical, 4)
                    }

                    if searchResults.isEmpty {
                        Text("No matching tags found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(searchResults, id: \.name) { item in
                            tagRow(item.name, count: item.count)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding()
        .frame(width: 320)
        .task {
            loadInitialData()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(query: newValue)
        }
    }

    private func tagRow(_ name: String, count: Int) -> some View {
        let selection = state.tagSelectionState(name, field: tagField)
        return HStack(spacing: 8) {
            Button {
                state.cycleTag(name, field: tagField)
                onTagChanged()
            } label: {
                HStack {
                    switch selection {
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

                    Text(name)
                        .lineLimit(1)
                        .strikethrough(selection == .excluded)
                        .foregroundColor(selection == .excluded ? .secondary : .primary)

                    Spacer()

                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button {
                    state.toggleInclude(name, field: tagField)
                    onTagChanged()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.bold())
                        .foregroundColor(selection == .included ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        .background(selection == .included ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Include this tag")

                Button {
                    state.toggleExclude(name, field: tagField)
                    onTagChanged()
                } label: {
                    Image(systemName: "minus")
                        .font(.caption2.bold())
                        .foregroundColor(selection == .excluded ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        .background(selection == .excluded ? Color.red : Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Exclude this tag")
            }
        }
        .padding(.vertical, 2)
    }

    private func loadInitialData() {
        let fandoms = Array(state.includedFandoms)
        Task {
            if !fandoms.isEmpty && field != .fandom {
                popularResults = await facetController.searchTags(
                    query: "", field: field, fandomContext: fandoms, limit: 10
                )
            }
            searchResults = await facetController.searchTags(
                query: "", field: field, fandomContext: [], limit: 20
            )
        }
    }

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        debouncer.schedule {
            searchTask = Task { @MainActor in
                let fandoms = Array(state.includedFandoms)
                let results = await facetController.searchTags(
                    query: query, field: field, fandomContext: fandoms, limit: 25
                )
                guard !Task.isCancelled else { return }
                searchResults = results
            }
        }
    }
}
