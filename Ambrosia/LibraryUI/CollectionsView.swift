import SwiftUI

struct CollectionsView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = ReaderPreferences.shared

    var bookToAdd: CalibreBook? = nil
    var calibreIDsToAdd: [Int] = []
    var onSelectCollection: ((CollectionRow) -> Void)? = nil

    @State private var collections: [CollectionRow] = []
    @State private var membership: [String: Set<Int>] = [:]
    @State private var newName = ""
    @State private var isCreating = false
    @State private var renamingID: String?
    @State private var renameText = ""

    private var selectedCalibreIDs: [Int] {
        if !calibreIDsToAdd.isEmpty { return calibreIDsToAdd }
        return bookToAdd.map { [$0.id] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                    if !selectedCalibreIDs.isEmpty && !isCreating {
                        Button {
                            isCreating = true
                            newName = ""
                        } label: {
                            Label("New Collection...", systemImage: "plus")
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
    }

    private var visibleCollections: [CollectionRow] {
        collections.filter { collection in
            if collection.id == SystemCollectionID.skipped {
                return prefs.showSkippedCollection
            }
            return !collection.isSystem || selectedCalibreIDs.isEmpty
        }
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

    @ViewBuilder
    private func collectionRow(_ collection: CollectionRow) -> some View {
        let isRenaming = renamingID == collection.id
        let count = membership[collection.id]?.count ?? 0
        let selected = Set(selectedCalibreIDs)
        let isMember = !selected.isEmpty && selected.isSubset(of: membership[collection.id] ?? [])

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
                if !selectedCalibreIDs.isEmpty {
                    Button {
                        toggleMembership(collection: collection)
                    } label: {
                        Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isMember ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
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
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            if !selectedCalibreIDs.isEmpty {
                toggleMembership(collection: collection)
            } else {
                onSelectCollection?(collection)
                dismiss()
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
                    Task { try? await session.collectionStore?.deleteCollection(id: collection.id); await reload() }
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
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let ids = selectedCalibreIDs
        Task {
            _ = try? await session.collectionStore?.createCollection(name: trimmed, calibreIDs: ids)
            await reload()
            isCreating = false
            newName = ""
        }
    }

    private func commitRename(_ collection: CollectionRow) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
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
            if selected.isSubset(of: members) {
                try? await session.collectionStore?.bulkRemove(calibreIDs: selectedCalibreIDs, from: collection.id)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: selectedCalibreIDs, to: collection.id)
            }
            await reload()
        }
    }
}

struct AddToCollectionMenu: View {
    let calibreIDs: [Int]
    @Environment(LibrarySession.self) private var session
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var collections: [CollectionRow] = []
    @State private var membership: [String: Set<Int>] = [:]
    @State private var showCreateSheet = false

    init(book: CalibreBook) {
        self.calibreIDs = [book.id]
    }

    init(calibreIDs: [Int]) {
        self.calibreIDs = calibreIDs
    }

    var body: some View {
        Menu("Add to Collection") {
            ForEach(visibleCollections) { collection in
                let selected = Set(calibreIDs)
                let isMember = !selected.isEmpty && selected.isSubset(of: membership[collection.id] ?? [])
                Button {
                    Task {
                        if isMember {
                            try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: collection.id)
                        } else {
                            try? await session.collectionStore?.bulkAdd(calibreIDs: calibreIDs, to: collection.id)
                        }
                        await reload()
                    }
                } label: {
                    if isMember {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }

            if !visibleCollections.isEmpty { Divider() }

            Button {
                showCreateSheet = true
            } label: {
                Label("New Collection...", systemImage: "plus")
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showCreateSheet) {
            CollectionsView(calibreIDsToAdd: calibreIDs)
        }
    }

    private var visibleCollections: [CollectionRow] {
        collections.filter { collection in
            if collection.id == SystemCollectionID.skipped {
                return prefs.showSkippedCollection
            }
            return !collection.isSystem
        }
    }

    private func reload() async {
        collections = (try? await session.collectionStore?.collections()) ?? []
        membership = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
    }
}
