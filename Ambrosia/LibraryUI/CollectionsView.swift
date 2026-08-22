import SwiftUI

/// Distinguishes "none of the selected books are members" from "some" from
/// "all", so a series selection under grouping (where membership is only
/// tracked per individual work, never per series) can render a mixed state
/// instead of collapsing "3 of 5" into the same empty state as "0 of 5".
enum MembershipState { case none, partial, all }

func membershipState(for members: Set<Int>, selected: Set<Int>) -> MembershipState {
    guard !selected.isEmpty else { return .none }
    let intersection = selected.intersection(members)
    if intersection.isEmpty { return .none }
    if intersection.count == selected.count { return .all }
    return .partial
}

struct CollectionsView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = ReaderPreferences.shared

    var bookToAdd: CalibreBook?
    var calibreIDsToAdd: [Int] = []
    var onSelectCollection: ((CollectionRow) -> Void)?

    @State private var collections: [CollectionRow] = []
    @State private var membership: [String: Set<Int>] = [:]
    @State private var newName = ""
    @State private var isCreating = false
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var pendingDeleteCollection: CollectionRow?

    private var selectedCalibreIDs: [Int] {
        if !calibreIDsToAdd.isEmpty { return calibreIDsToAdd }
        return bookToAdd.map { [$0.id] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()

            if visibleCollections.isEmpty && !isCreating {
                emptyState
            } else {
                List {
                    ForEach(visibleCollections) { collection in
                        collectionRow(collection)
                    }
                    if isCreating {
                        newCollectionRow
                    }
                    if let searchCreateName, !isCreating {
                        Button {
                            newName = searchCreateName
                            commitCreate()
                        } label: {
                            Label("Create \"\(searchCreateName)\"", systemImage: "plus")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    if !selectedCalibreIDs.isEmpty && !isCreating {
                        Button {
                            isCreating = true
                            newName = ""
                        } label: {
                            Label("New Collection…", systemImage: "plus")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 320)
        .task { await reload() }
        .confirmationDialog(
            "Delete “\(pendingDeleteCollection?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeleteCollection != nil },
                set: { if !$0 { pendingDeleteCollection = nil } }
            ),
            presenting: pendingDeleteCollection
        ) { collection in
            Button("Delete", role: .destructive) {
                Task {
                    try? await session.collectionStore?.deleteCollection(id: collection.id)
                    session.bumpMembershipVersion()  // §7
                    if renamingID == collection.id { renamingID = nil }
                    await reload()
                }
            }
        } message: { collection in
            Text("This removes \(membership[collection.id]?.count ?? 0) book(s) from this collection. The books themselves are not deleted.")
        }
    }

    private var visibleCollections: [CollectionRow] {
        let base = collections.filter { collection in
            if collection.id == SystemCollectionID.skipped {
                return prefs.showSkippedCollection
            }
            return !collection.isSystem || selectedCalibreIDs.isEmpty
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedStandardContains(query) }
    }

    private var searchCreateName: String? {
        guard !selectedCalibreIDs.isEmpty else { return nil }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasExact = collections.contains {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return hasExact ? nil : trimmed
    }

    private var header: some View {
        HStack {
            Text(selectedCalibreIDs.isEmpty ? "Collections" : "Add to Collection")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search collections", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func collectionRow(_ collection: CollectionRow) -> some View {
        let isRenaming = renamingID == collection.id
        let count = membership[collection.id]?.count ?? 0
        let selected = Set(selectedCalibreIDs)
        let state = membershipState(for: membership[collection.id] ?? [], selected: selected)

        HStack {
            if isRenaming {
                TextField("Collection name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(collection) }
                Button("Save") { commitRename(collection) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { renamingID = nil }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                Button {
                    if !selectedCalibreIDs.isEmpty {
                        toggleMembership(collection: collection)
                    } else {
                        onSelectCollection?(collection)
                        dismiss()
                    }
                } label: {
                    HStack {
                        if !selectedCalibreIDs.isEmpty {
                            Image(systemName: state == .all ? "checkmark.circle.fill" : (state == .partial ? "minus.circle.fill" : "circle"))
                                .foregroundStyle(state == .none ? .secondary : Color.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name).lineLimit(1)
                            Text("\(count) book\(count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()

                        if selectedCalibreIDs.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if !collection.isSystem {
                Button("Rename") {
                    renamingID = collection.id
                    renameText = collection.name
                }
                Divider()
                Button("Delete", role: .destructive) {
                    pendingDeleteCollection = collection
                }
            }
        }
    }

    private var newCollectionRow: some View {
        HStack {
            TextField("Collection name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitCreate() }
            Button("Create") { commitCreate() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { isCreating = false; newName = "" }
                .buttonStyle(.borderless).controlSize(.small)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.2").font(.system(size: 36)).foregroundStyle(.quaternary)
            Text("No Collections").font(.title3).foregroundStyle(.secondary)
            Button {
                isCreating = true
                newName = ""
            } label: {
                Label("New Collection", systemImage: "plus")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if selectedCalibreIDs.isEmpty {
            HStack {
                Button {
                    isCreating = true
                    newName = ""
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else {
            Color.clear.frame(height: 8)
        }
    }

    private func reload() async {
        collections = (try? await session.collectionStore?.collections()) ?? []
        membership = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
    }

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ids = selectedCalibreIDs
        Task {
            _ = try? await session.collectionStore?.createCollection(name: trimmed, calibreIDs: ids)
            session.bumpMembershipVersion()  // §7
            await reload()
            isCreating = false
            newName = ""
        }
    }

    private func commitRename(_ collection: CollectionRow) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { renamingID = nil; return }
        Task {
            try? await session.collectionStore?.renameCollection(id: collection.id, name: trimmed)
            await reload()
            renamingID = nil
        }
    }

    private func toggleMembership(collection: CollectionRow) {
        Task {
            let selected = Set(selectedCalibreIDs)
            let members = membership[collection.id] ?? []
            // Deliberate choice, not an oversight: a .partial row (e.g. 3 of
            // 5 works in a series already members) toggles to .all by adding
            // the remaining works, rather than removing the existing
            // members. This matches the existing .none -> .all "toggle to
            // full membership" semantics and is the less surprising of the
            // two options -- removing books the user didn't ask to remove
            // would be worse.
            if selected.isSubset(of: members) {
                try? await session.collectionStore?.bulkRemove(calibreIDs: selectedCalibreIDs, from: collection.id)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: selectedCalibreIDs, to: collection.id)
            }
            session.bumpMembershipVersion()  // §7
            await reload()
        }
    }
}

struct CollectionSearchPickerView: View {
    let calibreIDs: [Int]
    var onChange: (() async -> Void)?
    var onComplete: (() -> Void)?

    @Environment(LibrarySession.self) private var session
    @FocusState private var searchFocused: Bool
    @State private var collections: [CollectionRow] = []
    @State private var membership: [String: Set<Int>] = [:]
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or create collection", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCollections) { collection in
                        collectionButton(collection)
                    }

                    if let createName {
                        Button {
                            createCollection(named: createName)
                        } label: {
                            Label("Create \"\(createName)\"", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }

                    if filteredCollections.isEmpty && createName == nil {
                        Text("No collections")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 300)
        .task { await reload() }
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    private var targetCollections: [CollectionRow] {
        collections.filter { !$0.isSystem }
    }

    private var filteredCollections: [CollectionRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return targetCollections }
        return targetCollections.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var createName: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasExact = targetCollections.contains {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return hasExact ? nil : trimmed
    }

    private func collectionButton(_ collection: CollectionRow) -> some View {
        let selected = Set(calibreIDs)
        let state = membershipState(for: membership[collection.id] ?? [], selected: selected)
        return Button {
            toggleMembership(collection)
        } label: {
            HStack {
                Text(collection.name)
                    .lineLimit(1)
                Spacer()
                if state == .all {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                } else if state == .partial {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func reload() async {
        collections = (try? await session.collectionStore?.collections()) ?? []
        membership = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
    }

    private func toggleMembership(_ collection: CollectionRow) {
        Task {
            let selected = Set(calibreIDs)
            let members = membership[collection.id] ?? []
            // See CollectionsView.toggleMembership: a .partial selection
            // toggles to .all (adds the remaining works) rather than
            // removing the existing members.
            if selected.isSubset(of: members) {
                try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: collection.id)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: calibreIDs, to: collection.id)
            }
            session.bumpMembershipVersion()  // §7
            await reload()
            await onChange?()
            onComplete?()
        }
    }

    private func createCollection(named name: String) {
        Task {
            _ = try? await session.collectionStore?.createCollection(name: name, calibreIDs: calibreIDs)
            session.bumpMembershipVersion()  // §7
            await reload()
            await onChange?()
            onComplete?()
        }
    }
}
