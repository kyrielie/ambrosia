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
    @Bindable private var prefs = ReaderPreferences.shared

    var bookToAdd: CalibreBook?
    var calibreIDsToAdd: [Int] = []
    var onSelectCollection: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    @AppStorage("CollectionsView.lastSelectedCollectionID") private var lastSelectedCollectionID: String = SystemCollectionID.readLater

    @State private var collections: [CollectionRow] = []
    @State private var membership: [String: Set<Int>] = [:]
    @State private var selectedCollectionID: String?
    @State private var selectedWorkIDs: Set<Int> = []
    @State private var newName = ""
    @State private var isCreating = false
    @FocusState private var isCreatingFocused: Bool
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var pendingDeleteCollection: CollectionRow?
    @State private var memberBooks: [CalibreBook] = []
    @State private var memberAddedDates: [Int: Date] = [:]
    @State private var memberProgress: [Int: Double] = [:]

    private var selectedCalibreIDs: [Int] {
        if !calibreIDsToAdd.isEmpty { return calibreIDsToAdd }
        return bookToAdd.map { [$0.id] } ?? []
    }

    private var isPickerMode: Bool {
        !selectedCalibreIDs.isEmpty
    }

    var body: some View {
        Group {
            if isPickerMode {
                pickerLayout
            } else {
                splitViewLayout
            }
        }
        .frame(
            minWidth: isPickerMode ? 460 : 720,
            maxWidth: .infinity,
            minHeight: isPickerMode ? 380 : 480,
            maxHeight: .infinity
        )
        .task { await reload() }
        .onChange(of: selectedCollectionID) { _, newID in
            if let newID {
                lastSelectedCollectionID = newID
            }
        }
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
                    session.bumpMembershipVersion()
                    if renamingID == collection.id { renamingID = nil }
                    if selectedCollectionID == collection.id { selectedCollectionID = nil }
                    await reload()
                }
            }
        } message: { collection in
            Text("Are you sure you want to delete “\(collection.name)”? The works inside will remain in your library.")
        }
    }

    // MARK: - Split View Layout (Manager Mode)

    private var splitViewLayout: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                sidebarView
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
                detailView
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "tray.2.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            Text("Collections")
                .font(.headline)
            Spacer()
            Button("Done") {
                doDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sidebarView: some View {
        VStack(spacing: 0) {
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
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            List(selection: $selectedCollectionID) {
                Section("Smart Collections") {
                    smartRow(
                        id: SystemCollectionID.readLater,
                        name: "Read Later",
                        icon: "bookmark.fill",
                        color: .accentColor,
                        count: session.cachedReadLaterIDs.count
                    )
                    smartRow(
                        id: SystemCollectionID.liked,
                        name: "Liked Works",
                        icon: "heart.fill",
                        color: .pink,
                        count: session.cachedLikedIDs.count
                    )
                }

                Section("My Collections") {
                    ForEach(visibleCollections) { col in
                        userCollectionRow(col)
                            .tag(col.id)
                    }
                    if isCreating {
                        newCollectionInlineRow
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    newName = "Untitled Collection"
                    isCreating = true
                    DispatchQueue.main.async {
                        isCreatingFocused = true
                    }
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)

                Spacer()

                Text("\(collections.count) collections")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(maxHeight: .infinity)
    }

    private func handleDrop(providers: [NSItemProvider], targetCollectionID: String) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { string, _ in
            guard let str = string as? String else { return }
            let ids = str.split(separator: ",").compactMap { Int($0) }
            guard !ids.isEmpty else { return }
            Task { @MainActor in
                try? await session.collectionStore?.bulkAdd(calibreIDs: ids, to: targetCollectionID)
                session.bumpMembershipVersion()
                await reload()
            }
        }
        return true
    }

    private func smartRow(id: String, name: String, icon: String, color: Color, count: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(name)
                .font(.body)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .tag(id)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers, targetCollectionID: id)
        }
        .contextMenu {
            Button("Show in Library") {
                let filterName = resolveCollectionFilterName(for: id)
                if !filterName.isEmpty {
                    onSelectCollection?(filterName)
                    doDismiss()
                }
            }
        }
    }

    private func userCollectionRow(_ col: CollectionRow) -> some View {
        let count = membership[col.id]?.count ?? 0
        let isRenaming = renamingID == col.id

        return HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .frame(width: 18)
            if isRenaming {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(col) }
                Button("Save") { commitRename(col) }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                Button("Cancel") { renamingID = nil }
                    .buttonStyle(.borderless).controlSize(.mini)
            } else {
                Text(col.name)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .tag(col.id)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers, targetCollectionID: col.id)
        }
        .contextMenu {
            Button("Show in Library") {
                let filterName = resolveCollectionFilterName(for: col.id)
                if !filterName.isEmpty {
                    onSelectCollection?(filterName)
                    doDismiss()
                }
            }
            Divider()
            Button("Rename…") {
                renamingID = col.id
                renameText = col.name
            }
            Button("Delete", role: .destructive) {
                pendingDeleteCollection = col
            }
        }
    }

    private var newCollectionInlineRow: some View {
        HStack {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            TextField("Collection name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($isCreatingFocused)
                .onSubmit { commitCreate() }
                .onExitCommand {
                    isCreating = false
                    newName = ""
                }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail View

    private var detailView: some View {
        VStack(spacing: 0) {
            if let selectedID = selectedCollectionID {
                collectionDetailContent(for: selectedID)
                    .task(id: selectedID) {
                        await loadMemberBooks(for: selectedID)
                    }
            } else {
                ContentUnavailableView(
                    "Select a Collection",
                    systemImage: "tray.2",
                    description: Text("Choose a collection from the sidebar to inspect member works and manage contents.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func collectionDetailContent(for collectionID: String) -> some View {
        let (name, _, isSystem) = resolveCollectionMeta(for: collectionID)
        let totalWords = memberBooks.compactMap(\.wordCount).reduce(0, +)

        VStack(alignment: .leading, spacing: 0) {
            // Header card
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.title2.bold())
                        Text("\(memberBooks.count) \(memberBooks.count == 1 ? "work" : "works") • \(formatWords(totalWords))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        let filterName = resolveCollectionFilterName(for: collectionID)
                        if !filterName.isEmpty {
                            onSelectCollection?(filterName)
                            doDismiss()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 13, weight: .medium))
                            Text("Show in Library")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.accentColor)
                    .controlSize(.regular)
                    .help("Filter library to show only works from this collection")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Members Table / List
            if memberBooks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "books.vertical")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("No Works in this Collection")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add works by secondary-clicking them in the library list or email sidebar.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedWorkIDs) {
                    ForEach(memberBooks) { book in
                        memberRow(book: book, collectionID: collectionID, isSystem: isSystem)
                            .tag(book.id)
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand {
                    if !isSystem && !selectedWorkIDs.isEmpty {
                        batchRemoveSelectedWorks(from: collectionID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func memberRow(book: CalibreBook, collectionID: String, isSystem: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(book.displayAuthors.isEmpty ? "Unknown Author" : book.displayAuthors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let words = book.wordCount, words > 0 {
                        Text("•").foregroundStyle(.tertiary)
                        Text(formatWords(words))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = memberAddedDates[book.id] {
                        Text("•").foregroundStyle(.tertiary)
                        Text(formatAddedDate(date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let pct = memberProgress[book.id] {
                        if pct >= 0.98 {
                            Text("•").foregroundStyle(.tertiary)
                            Label("Finished", systemImage: "checkmark.circle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        } else if pct > 0.01 {
                            Text("•").foregroundStyle(.tertiary)
                            Text("\(Int((pct * 100).rounded()))% read")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            Spacer()

            if !isSystem {
                Button {
                    removeBookFromCollection(calibreID: book.id, collectionID: collectionID)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from collection")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onDrag {
            let ids = selectedWorkIDs.contains(book.id) ? Array(selectedWorkIDs) : [book.id]
            let str = ids.map(String.init).joined(separator: ",")
            return NSItemProvider(object: str as NSString)
        }
        .onTapGesture(count: 2) {
            openWork(book)
        }
        .contextMenu {
            Button("Open in Reader") {
                openWork(book)
            }
            if !isSystem {
                Divider()
                if selectedWorkIDs.contains(book.id) && selectedWorkIDs.count > 1 {
                    Button("Remove \(selectedWorkIDs.count) Works from Collection", role: .destructive) {
                        batchRemoveSelectedWorks(from: collectionID)
                    }
                } else {
                    Button("Remove from Collection", role: .destructive) {
                        removeBookFromCollection(calibreID: book.id, collectionID: collectionID)
                    }
                }
            }
        }
    }

    private func batchRemoveSelectedWorks(from collectionID: String) {
        let ids = Array(selectedWorkIDs)
        selectedWorkIDs.removeAll()
        Task {
            try? await session.collectionStore?.bulkRemove(calibreIDs: ids, from: collectionID)
            session.bumpMembershipVersion()
            await reload()
        }
    }

    private func openWork(_ book: CalibreBook) {
        AppDelegate.shared?.openReaderWindow(book: book)
        doDismiss()
    }

    private func resolveCollectionFilterName(for id: String) -> String {
        if id == SystemCollectionID.readLater {
            return "Read Later"
        }
        if id == SystemCollectionID.liked {
            return "Liked"
        }
        if let col = collections.first(where: { $0.id == id }) {
            return col.name
        }
        return ""
    }

    private func resolveCollectionMeta(for id: String) -> (name: String, memberIDs: Set<Int>, isSystem: Bool) {
        if id == SystemCollectionID.readLater {
            return ("Read Later", session.cachedReadLaterIDs, true)
        }
        if id == SystemCollectionID.liked {
            return ("Liked Works", session.cachedLikedIDs, true)
        }
        if let col = collections.first(where: { $0.id == id }) {
            return (col.name, membership[col.id] ?? [], false)
        }
        return ("Collection", [], false)
    }

    private func loadMemberBooks(for collectionID: String) async {
        let (_, memberIDs, _) = resolveCollectionMeta(for: collectionID)
        guard let library = session.library, !memberIDs.isEmpty else {
            await MainActor.run {
                self.memberBooks = []
                self.memberAddedDates = [:]
                self.memberProgress = [:]
                self.selectedWorkIDs.removeAll()
            }
            return
        }
        let idsArray = Array(memberIDs)
        async let booksTask = library.booksForIDs(idsArray)
        async let datesTask = session.collectionStore?.memberAddedDates(for: collectionID)
        let states = session.metaDB?.bookStates(for: idsArray) ?? [:]
        let (books, dates) = await (booksTask, (try? datesTask) ?? [:])
        let progressMap = states.mapValues { $0.totalReadPercent }
        await MainActor.run {
            self.memberBooks = books
            self.memberAddedDates = dates
            self.memberProgress = progressMap
            self.selectedWorkIDs.removeAll()
        }
    }

    private func formatAddedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Added \(formatter.string(from: date))"
    }

    private func removeBookFromCollection(calibreID: Int, collectionID: String) {
        Task {
            try? await session.collectionStore?.bulkRemove(calibreIDs: [calibreID], from: collectionID)
            session.bumpMembershipVersion()
            await reload()
        }
    }

    private func formatWords(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM words", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.0fk words", Double(count) / 1_000.0)
        }
        return "\(count) words"
    }

    // MARK: - Picker Mode (Add to Collection)

    private var pickerLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to Collection")
                    .font(.headline)
                Spacer()
                Button("Done") { doDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search collections", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
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

            Divider()

            List {
                ForEach(visibleCollections) { col in
                    let selected = Set(selectedCalibreIDs)
                    let state = membershipState(for: membership[col.id] ?? [], selected: selected)
                    Button {
                        toggleMembership(collection: col)
                    } label: {
                        HStack {
                            Image(systemName: state == .all ? "checkmark.circle.fill" : (state == .partial ? "minus.circle.fill" : "circle"))
                                .foregroundStyle(state == .none ? .secondary : Color.accentColor)
                            Text(col.name)
                            Spacer()
                            let count = membership[col.id]?.count ?? 0
                            Text("\(count) books")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if isCreating {
                    newCollectionInlineRow
                } else {
                    Button {
                        isCreating = true
                        newName = ""
                    } label: {
                        Label("New Collection…", systemImage: "plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private var visibleCollections: [CollectionRow] {
        let user = collections.filter { !$0.isSystem }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return user }
        return user.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func doDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func reload() async {
        collections = (try? await session.collectionStore?.collections()) ?? []
        membership = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
        if selectedCollectionID == nil {
            selectedCollectionID = lastSelectedCollectionID
        }
        if let sel = selectedCollectionID {
            await loadMemberBooks(for: sel)
        }
    }

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = false
        newName = ""
        guard !trimmed.isEmpty else { return }
        let ids = selectedCalibreIDs
        Task {
            if let created = try? await session.collectionStore?.createCollection(name: trimmed, calibreIDs: ids) {
                session.bumpMembershipVersion()
                await reload()
                selectedCollectionID = created.id
            }
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
            if selected.isSubset(of: members) {
                try? await session.collectionStore?.bulkRemove(calibreIDs: selectedCalibreIDs, from: collection.id)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: selectedCalibreIDs, to: collection.id)
            }
            session.bumpMembershipVersion()
            await reload()
        }
    }
}

// MARK: - CollectionSearchPickerView (Retained for Popover Context Menus)

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
                    Image(systemName: "minus")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        collections = (try? await session.collectionStore?.collections()) ?? []
        membership = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
    }

    private func toggleMembership(_ collection: CollectionRow) {
        Task {
            let selected = Set(calibreIDs)
            let members = membership[collection.id] ?? []
            if selected.isSubset(of: members) {
                try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: collection.id)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: calibreIDs, to: collection.id)
            }
            session.bumpMembershipVersion()
            await reload()
            await onChange?()
        }
    }

    private func createCollection(named name: String) {
        Task {
            _ = try? await session.collectionStore?.createCollection(name: name, calibreIDs: calibreIDs)
            session.bumpMembershipVersion()
            searchText = ""
            await reload()
            await onChange?()
        }
    }
}
