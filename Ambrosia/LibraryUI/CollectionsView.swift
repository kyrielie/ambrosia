import SwiftUI
import SwiftData

// MARK: - Collections sheet

/// Sheet that lets the user manage named collections of books.
///
/// Two modes:
///  • Normal mode (bookToAdd == nil): list of collections; clicking one fires
///    `onSelectCollection` so the library can switch to a filtered view.
///  • "Add to collection" mode (bookToAdd != nil): each row shows a toggle;
///    also has a "New Collection…" row that creates and immediately adds the book.
///
/// Collection membership is stored as comma-separated Calibre IDs in
/// `Collection.calibreIDsRaw` — never as [Int] on the @Model.
struct CollectionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the sheet is in "add to collection" mode.
    var bookToAdd: CalibreBook? = nil
    /// Called in normal mode when the user taps a collection row.
    var onSelectCollection: ((Collection) -> Void)? = nil

    @Query(sort: \Collection.createdDate) private var collections: [Collection]

    @State private var newName = ""
    @State private var isCreating = false
    @State private var renamingID: PersistentIdentifier? = nil
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if collections.isEmpty && !isCreating {
                emptyState
            } else {
                List {
                    ForEach(collections) { collection in
                        collectionRow(collection)
                    }
                    if isCreating {
                        newCollectionRow
                    }
                    // "Add to collection" mode: always show a "New Collection…" entry
                    if bookToAdd != nil && !isCreating {
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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(bookToAdd == nil ? "Collections" : "Add to Collection")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    @ViewBuilder
    private func collectionRow(_ collection: Collection) -> some View {
        let isRenaming = renamingID == collection.persistentModelID
        let count      = collection.calibreIDs.count
        let isMember   = bookToAdd.map { collection.contains(calibreID: $0.id) } ?? false

        HStack {
            if isRenaming {
                TextField("Collection name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(collection) }
                Button("Save")   { commitRename(collection) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { renamingID = nil }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                // "Add to collection" mode: toggle circle
                if let book = bookToAdd {
                    Button {
                        toggleMembership(book: book, in: collection)
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

                // Normal mode: chevron indicating the row is tappable
                if bookToAdd == nil {
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            if let book = bookToAdd {
                toggleMembership(book: book, in: collection)
            } else {
                // Normal mode: activate the collection filter and close
                onSelectCollection?(collection)
                dismiss()
            }
        }
        .contextMenu {
            Button("Rename") {
                renamingID = collection.persistentModelID
                renameText = collection.name
            }
            Divider()
            Button("Delete", role: .destructive) {
                modelContext.delete(collection)
                try? modelContext.save()
            }
        }
    }

    // MARK: - New collection row

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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.2").font(.system(size: 36)).foregroundStyle(.quaternary)
            Text("No Collections").font(.title3).foregroundStyle(.secondary)
            Text("Create a collection to organise your books.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
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

    // MARK: - Footer (normal mode only)

    @ViewBuilder
    private var footer: some View {
        if bookToAdd == nil {
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
            // In "add" mode the footer is just padding
            Color.clear.frame(height: 8)
        }
    }

    // MARK: - Actions

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let col = Collection(name: trimmed)
        if let book = bookToAdd {
            col.add(calibreID: book.id)
        }
        modelContext.insert(col)
        try? modelContext.save()
        isCreating = false
        newName = ""
    }

    private func commitRename(_ collection: Collection) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { collection.name = trimmed }
        try? modelContext.save()
        renamingID = nil
    }

    private func toggleMembership(book: CalibreBook, in collection: Collection) {
        if collection.contains(calibreID: book.id) {
            collection.remove(calibreID: book.id)
        } else {
            collection.add(calibreID: book.id)
        }
        try? modelContext.save()
    }
}

// MARK: - "Add to collection" submenu for context menus

/// Dropped inside a `.contextMenu { }` block on a BookListRow.
/// Lists existing collections with a checkmark for membership, plus
/// a "New Collection…" item that creates and immediately adds the book.
struct AddToCollectionMenu: View {
    let book: CalibreBook
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Collection.createdDate) private var collections: [Collection]

    @State private var showCreateSheet = false

    var body: some View {
        Menu("Add to Collection") {
            ForEach(collections) { collection in
                let isMember = collection.contains(calibreID: book.id)
                Button {
                    toggle(book: book, in: collection)
                } label: {
                    if isMember {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }

            if !collections.isEmpty { Divider() }

            Button {
                showCreateSheet = true
            } label: {
                Label("New Collection…", systemImage: "plus")
            }
        }
        // Sheet must be attached outside the Menu to render correctly on macOS
        .sheet(isPresented: $showCreateSheet) {
            CollectionsView(bookToAdd: book)
        }
    }

    private func toggle(book: CalibreBook, in collection: Collection) {
        if collection.contains(calibreID: book.id) {
            collection.remove(calibreID: book.id)
        } else {
            collection.add(calibreID: book.id)
        }
        try? modelContext.save()
    }
}
