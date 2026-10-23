import AppKit
import Combine
import SwiftUI

// MARK: - EmailLibraryViewController
//
// Refactored in Phase 2 (Presentation Model & View Controller Unification).
// Three-pane email-style reading interface backed by `LibraryDisplayController`.
// All query planning, pagination offset tracking, series grouping, and
// metadata hydration are managed centrally by `displayController`.

final class EmailLibraryViewController: NSViewController {

    // MARK: - Dependencies

    let session: LibrarySession
    let toolbarState: LibraryToolbarState
    let displayController: LibraryDisplayController

    // MARK: - Child VCs

    private var splitVC: AmbrosiaEmailSplitViewController!
    private var sidebarVC: EmailSidebarViewController!
    private var readerSidebarHostingVC: NSHostingController<EmailReaderSidebarView>!
    private var librarySidebarItem: NSSplitViewItem!
    private var readerPaneItem: NSSplitViewItem!
    private var annotationsSidebarItem: NSSplitViewItem!

    // MARK: - Popovers & Sheets

    private var filterSheetHost: NSHostingView<FilterSheetCarrier>?
    private var collectionPickerPopover: NSPopover?
    private var preferenceCancellables: Set<AnyCancellable> = []

    // MARK: - Sidebar & Split State

    private var isSidebarHidden = false
    private var lastSidebarThickness: CGFloat = 280
    private var pendingCollectionSeedIDs: [Int] = []

    // MARK: - Toolbar Toggle Baselines

    private var lastSidebarToggle: Bool = false
    private var lastReaderSidebarToggle: Bool = false
    private var lastShowReaderSidebarToggle: Bool = false

    // MARK: - Reader State

    private var selectedBook: CalibreBook?
    private weak var currentReaderVC: ReaderViewController?
    private var readerLocalFindState = LocalReaderFindState()
    private var lastAppliedFullTextPhrase = ""
    private weak var lastAppliedFullTextReader: ReaderViewController?
    private var pendingFullTextPhrase = ""
    private var readerAnnotations: [Annotation] = []
    private var readerSidebarMode: EmailReaderSidebarMode = .annotations

    // MARK: - Computed Properties

    var currentBooks: [CalibreBook] {
        displayController.books
    }

    var activeCollectionID: String? {
        let collectionRules = toolbarState.filterExpression.groups.flatMap(\.rules)
            .filter { $0.field == .collection && $0.op == .equals }
        guard collectionRules.count == 1 else { return nil }
        return collectionRules[0].value
    }

    // MARK: - Initializers

    init(
        session: LibrarySession,
        toolbarState: LibraryToolbarState,
        displayController: LibraryDisplayController
    ) {
        self.session = session
        self.toolbarState = toolbarState
        self.displayController = displayController
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(session: LibrarySession, toolbarState: LibraryToolbarState) {
        self.init(
            session: session,
            toolbarState: toolbarState,
            displayController: LibraryDisplayController(session: session, toolbarState: toolbarState)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        toolbarState.isEmailReaderSidebarVisible = false
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbarState.isEmailReaderSidebarVisible = false
        buildSplitView()
        addFilterSheetHost()
        startObservingPreferences()
        startObservingToolbarToggles()
        startObservingDisplayController()
        syncSidebarFromDisplayController()
    }

    // MARK: - Split-View Setup

    private func buildSplitView() {
        sidebarVC = EmailSidebarViewController()
        sidebarVC.toolbarState = toolbarState
        sidebarVC.onSelect = { [weak self] book in self?.setSelectedBook(book) }
        sidebarVC.onOpen = { target in
            AppDelegate.shared?.openReaderWindow(target: target)
        }
        sidebarVC.onLoadMore = { [weak self] in
            self?.displayController.loadNextBatchIfAvailable()
        }
        sidebarVC.onRetryTapped = { [weak self] in
            self?.displayController.reloadCurrentPage()
        }
        sidebarVC.onEditFilter = { [weak self] in
            self?.toolbarState.showFilterDrawer = true
        }
        sidebarVC.onClearFilter = { [weak self] in
            guard let self else { return }
            self.toolbarState.filterExpression = FilterExpression()
            self.toolbarState.activeFilterResult = nil
            self.toolbarState.cancelLibraryFilterApplication()
            self.displayController.scheduleLoadPage()
        }
        sidebarVC.onContextMenuOpen = { books in
            for book in books {
                AppDelegate.shared?.openReaderWindow(book: book)
            }
        }
        sidebarVC.onContextMenuSetLiked = { [weak self] books, liked in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.setLiked(calibreIDs: books.map(\.id), liked: liked)
                self.session.bumpMembershipVersion()
                await self.displayController.refreshVisibilitySnapshots(resetPage: false)
            }
        }
        sidebarVC.onToggleLiked = { [weak self] books in
            guard let self, !books.isEmpty else { return }
            Task {
                let shouldLike = !books.allSatisfy { self.session.cachedLikedIDs.contains($0.id) }
                try? await self.session.collectionStore?.setLiked(calibreIDs: books.map(\.id), liked: shouldLike)
                self.session.bumpMembershipVersion()
                await self.displayController.refreshVisibilitySnapshots(resetPage: false)
            }
        }
        sidebarVC.onToggleReadLater = { [weak self] books in
            self?.toggleReadLater(for: books)
        }
        sidebarVC.onContextMenuReadLater = { [weak self] books in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.bulkAdd(calibreIDs: books.map(\.id), to: SystemCollectionID.readLater)
                self.session.bumpMembershipVersion()
                await self.displayController.refreshVisibilitySnapshots(resetPage: false)
            }
        }
        sidebarVC.onContextMenuSkip = { [weak self] books in
            guard let self else { return }
            Task {
                for book in books {
                    try? await self.session.collectionStore?.skipBook(calibreID: book.id)
                }
                self.session.bumpMembershipVersion()
                await self.displayController.refreshVisibilitySnapshots(resetPage: false)
            }
        }
        sidebarVC.onContextMenuMarkRead = { [weak self] books in
            self?.markRead(books)
        }
        sidebarVC.onContextMenuResetProgress = { [weak self] books in
            self?.resetProgress(books)
        }
        sidebarVC.onContextMenuCollectionPicker = { [weak self] books, anchorView, anchorRect in
            guard let self else { return }
            self.showCollectionPicker(for: books.map(\.id), relativeTo: anchorRect, of: anchorView)
        }
        sidebarVC.onContextMenuRemoveFromCollection = { [weak self] books, collectionID in
            self?.removeFromCollection(named: collectionID, calibreIDs: books.map(\.id))
        }

        splitVC = AmbrosiaEmailSplitViewController()
        splitVC.splitView.isVertical = true
        splitVC.splitView.autosaveName = "AmbrosiaEmailSplitView"
        splitVC.onDividerResize = { [weak self] in
            self?.rememberSidebarThicknessIfVisible()
        }
        applyLibraryAppearance()

        librarySidebarItem = NSSplitViewItem(viewController: sidebarVC)
        librarySidebarItem.minimumThickness = 200
        librarySidebarItem.maximumThickness = 380
        librarySidebarItem.preferredThicknessFraction = 0.26
        librarySidebarItem.canCollapse = true

        readerPaneItem = NSSplitViewItem(viewController: makePlaceholderVC())
        readerPaneItem.minimumThickness = 420
        readerPaneItem.canCollapse = false

        annotationsSidebarItem = NSSplitViewItem(viewController: makeReaderSidebarVC())
        annotationsSidebarItem.minimumThickness = 240
        annotationsSidebarItem.maximumThickness = 360
        annotationsSidebarItem.preferredThicknessFraction = 0.24
        annotationsSidebarItem.canCollapse = true
        annotationsSidebarItem.isCollapsed = true

        splitVC.addSplitViewItem(librarySidebarItem)
        splitVC.addSplitViewItem(annotationsSidebarItem)
        splitVC.addSplitViewItem(readerPaneItem)

        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitVC.view)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        DispatchQueue.main.async { [weak self] in
            self?.rememberSidebarThickness()
        }
    }

    // MARK: - Display Controller Observation

    private func startObservingDisplayController() {
        observeDisplayController()
    }

    private func observeDisplayController() {
        withObservationTracking {
            _ = self.displayController.items
            _ = self.displayController.bookStates
            _ = self.displayController.ao3Metadata
            _ = self.displayController.rebuildDegraded
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncSidebarFromDisplayController()
                self.observeDisplayController()
            }
        }
    }

    private func syncSidebarFromDisplayController() {
        guard let sidebar = sidebarVC else { return }
        sidebar.items = displayController.items
        sidebar.bookStates = displayController.bookStates
        sidebar.ao3Metadata = displayController.ao3Metadata
        sidebar.likedIDs = session.cachedLikedIDs
        sidebar.readLaterIDs = session.cachedReadLaterIDs
        sidebar.collectionMembership = session.collectionMembershipByName
        sidebar.rebuildDegraded = displayController.rebuildDegraded
        sidebar.activeCollectionID = activeCollectionID
    }

    // MARK: - Toolbar Toggles Observation

    private func startObservingToolbarToggles() {
        scheduleToolbarToggleObservation()
    }

    private func scheduleToolbarToggleObservation() {
        withObservationTracking {
            _ = self.toolbarState.toggleEmailSidebar
            _ = self.toolbarState.toggleEmailReaderSidebar
            _ = self.toolbarState.showEmailReaderSidebar
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleToolbarToggles()
                self.scheduleToolbarToggleObservation()
            }
        }
    }

    private func handleToolbarToggles() {
        if toolbarState.toggleEmailSidebar != lastSidebarToggle {
            lastSidebarToggle = toolbarState.toggleEmailSidebar
            performSidebarToggle()
        }
        if toolbarState.toggleEmailReaderSidebar != lastReaderSidebarToggle {
            lastReaderSidebarToggle = toolbarState.toggleEmailReaderSidebar
            performReaderSidebarToggle()
        }
        if toolbarState.showEmailReaderSidebar != lastShowReaderSidebarToggle {
            lastShowReaderSidebarToggle = toolbarState.showEmailReaderSidebar
            switch toolbarState.emailReaderSidebarMode {
            case .annotations:
                showEmailAnnotationSidebar(nil)
            case .tableOfContents:
                showTOCInEmailSidebar(nil)
            }
        }
    }

    // MARK: - Preferences Observation

    private func startObservingPreferences() {
        withObservationTracking {
            _ = ReaderPreferences.shared.libraryAppearanceMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyLibraryAppearance()
                self?.startObservingPreferences()
            }
        }

        withObservationTracking {
            _ = ReaderPreferences.shared.emailPillsShowCollections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sidebarVC?.reloadAppearance()
                self?.startObservingEmailPillsPreference()
            }
        }
    }

    private func startObservingEmailPillsPreference() {
        withObservationTracking {
            _ = ReaderPreferences.shared.emailPillsShowCollections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sidebarVC?.reloadAppearance()
                self?.startObservingEmailPillsPreference()
            }
        }
    }

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        view.appearance = appearance
        splitVC?.view.appearance = appearance
        sidebarVC?.view.appearance = appearance
        filterSheetHost?.appearance = appearance
        sidebarVC?.reloadAppearance()
    }

    // MARK: - Filter Sheet Host & Collection Picker

    private func addFilterSheetHost() {
        let carrier = FilterSheetCarrier(
            toolbarState: toolbarState,
            session: session,
            displayController: displayController,
            emailVC: self
        )
        let hv = NSHostingView(rootView: carrier)
        hv.sizingOptions = []
        hv.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        hv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.widthAnchor.constraint(equalToConstant: 0),
            hv.heightAnchor.constraint(equalToConstant: 0),
            hv.topAnchor.constraint(equalTo: view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ])
        filterSheetHost = hv
    }

    private func showCollectionPicker(for calibreIDs: [Int], relativeTo rect: NSRect, of anchorView: NSView) {
        collectionPickerPopover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        let root = CollectionSearchPickerView(
            calibreIDs: calibreIDs,
            onChange: { [weak self] in
                await self?.displayController.refreshVisibilitySnapshots(resetPage: false)
            },
            onComplete: { [weak popover] in
                popover?.close()
            }
        )
        .environment(session)
        .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
        popover.contentViewController = NSHostingController(rootView: root)
        collectionPickerPopover = popover
        popover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxX)
    }

    private func removeFromCollection(named collectionName: String, calibreIDs: [Int]) {
        Task {
            guard let collections = try? await session.collectionStore?.collections(),
                  let match = collections.first(where: { $0.name == collectionName }) else { return }
            try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: match.id)
            CollectionAssignment.didAssign(session: session) { [weak self] in
                Task {
                    await self?.displayController.refreshVisibilitySnapshots(resetPage: false)
                }
            }
        }
    }

    func consumePendingCollectionSeedIDs() -> [Int] {
        let ids = pendingCollectionSeedIDs
        pendingCollectionSeedIDs = []
        return ids
    }

    // MARK: - Row Actions

    private func toggleReadLater(for books: [CalibreBook]) {
        let ids = books.map(\.id)
        let shouldAdd = !books.allSatisfy { session.cachedReadLaterIDs.contains($0.id) }
        Task {
            try? await session.collectionStore?.setReadLater(calibreIDs: ids, inReadLater: shouldAdd)
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func markRead(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            if let metaDB = session.metaDB {
                for calibreID in ids {
                    try? await metaDB.markBookRead(calibreID: calibreID)
                }
            }
            for calibreID in ids {
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.finished,
                    calibreID: calibreID,
                    shouldBeMember: true
                )
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.inProgress,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
            }
            session.bumpMembershipVersion()
            displayController.refreshBookStates()
        }
    }

    private func resetProgress(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            if let metaDB = session.metaDB {
                for calibreID in ids {
                    try? await metaDB.resetReadingProgress(calibreID: calibreID)
                }
            }
            for calibreID in ids {
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.finished,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.inProgress,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
            }
            session.bumpMembershipVersion()
            displayController.refreshBookStates()
        }
    }

    // MARK: - Inline Reader Pane

    private func setSelectedBook(_ book: CalibreBook?) {
        if selectedBook == nil, book == nil { return }
        if let selectedBook, let book,
           selectedBook.id == book.id,
           let currentReaderVC,
           currentReaderVC.book.id == book.id {
            return
        }
        selectedBook = book
        updateReaderPane()
    }

    private func updateReaderPane() {
        readerLocalFindState = LocalReaderFindState()
        lastAppliedFullTextPhrase = ""
        lastAppliedFullTextReader = nil
        pendingFullTextPhrase = activeFullTextPhrase()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        readerAnnotations = []
        currentReaderVC = nil
        replaceRightPane(with: makeRightVC())
        refreshReaderSidebar()
    }

    private func makeRightVC() -> NSViewController {
        guard let book = selectedBook else { return makePlaceholderVC() }
        let rvc = ReaderViewController(book: book)
        currentReaderVC = rvc
        rvc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        rvc.onReadingProgressChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.displayController.refreshBookStates()
            }
        }
        rvc.onAnnotationsChanged = { [weak self] annotations in
            DispatchQueue.main.async {
                self?.readerAnnotations = annotations
                self?.refreshReaderSidebar()
            }
        }
        rvc.onLocalFindStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.readerLocalFindState = state
                self?.refreshReaderSidebar()
            }
        }
        rvc.onOpenSearchSidebar = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshReaderSidebar()
            }
        }
        rvc.onReaderContentReady = { [weak self, weak rvc] in
            DispatchQueue.main.async {
                guard let self, let rvc, self.currentReaderVC === rvc else { return }
                self.applyFullTextPhraseToLocalFind(reader: rvc, allowDeferred: false)
            }
        }
        readerLocalFindState = rvc.currentLocalFindState()
        let cid = book.id
        Task {
            if let metaDB = session.metaDB {
                try? await metaDB.markBookOpened(calibreID: cid)
            }
        }
        return rvc
    }

    private func replaceRightPane(with vc: NSViewController) {
        let sidebarThickness = currentSidebarThickness()
        let oldItem = readerPaneItem
        let oldVC = oldItem?.viewController
        if let oldItem, splitVC.splitViewItems.contains(oldItem) {
            splitVC.removeSplitViewItem(oldItem)
        }
        splitVC.addChild(vc)
        vc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 420
        item.canCollapse = false
        readerPaneItem = item
        splitVC.addSplitViewItem(item)
        oldVC?.removeFromParent()
        restoreSidebarThickness(sidebarThickness)
    }

    private func makePlaceholderVC() -> NSViewController {
        NSHostingController(rootView:
            VStack(spacing: 14) {
                Image(systemName: "book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a book to read")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Filter by tag in the list view, then switch here to read through results.")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
        )
    }

    private func makeReaderSidebarVC() -> NSViewController {
        let vc = NSHostingController(rootView: makeReaderSidebarView())
        readerSidebarHostingVC = vc
        return vc
    }

    private func makeReaderSidebarView() -> EmailReaderSidebarView {
        EmailReaderSidebarView(
            mode: readerSidebarMode,
            annotations: readerAnnotations,
            onJumpToAnnotation: { [weak self] annotation in
                self?.currentReaderVC?.jumpToAnnotation(annotation)
            },
            onDeleteAnnotation: { [weak self] id in
                self?.currentReaderVC?.deleteAnnotationFromSidebar(id: id)
            },
            tocEntries: currentReaderVC?.globalTOCEntries ?? [],
            currentSpineIndex: currentReaderVC?.currentSpineIndexValue ?? 0,
            onJumpToTOCEntry: { [weak self] entry in
                self?.currentReaderVC?.jumpToTOCEntry(entry)
            }
        )
    }

    private func refreshReaderSidebar() {
        readerSidebarHostingVC?.rootView = makeReaderSidebarView()
    }

    private func activeFullTextPhrase() -> String? {
        if let phrase = SearchQueryParser.parse(toolbarState.searchText).fulltextPhrase,
           !phrase.isEmpty {
            return phrase
        }
        return toolbarState.filterExpression.groups
            .flatMap(\.rules)
            .first { $0.field == .fulltext && $0.op == .contains && $0.isComplete }?
            .value
    }

    private func applyFullTextPhraseToLocalFind(reader: ReaderViewController? = nil, allowDeferred: Bool = true) {
        let phrase = ReaderPreferences.shared.autoOpenFindBarForFullTextSearch
            ? (activeFullTextPhrase() ?? "")
            : ""
        let targetReader = reader ?? currentReaderVC
        guard let targetReader else { return }
        pendingFullTextPhrase = phrase
        guard targetReader.isReaderContentReady else {
            if !phrase.isEmpty && allowDeferred { return }
            if phrase.isEmpty,
               lastAppliedFullTextReader === targetReader,
               !lastAppliedFullTextPhrase.isEmpty {
                targetReader.setLocalFindText("")
                lastAppliedFullTextPhrase = ""
                lastAppliedFullTextReader = nil
            }
            return
        }
        if phrase.isEmpty {
            if lastAppliedFullTextReader === targetReader, !lastAppliedFullTextPhrase.isEmpty {
                targetReader.setLocalFindText("")
            }
        } else {
            targetReader.showLocalFind()
            targetReader.setLocalFindText(phrase)
        }
        lastAppliedFullTextPhrase = phrase
        lastAppliedFullTextReader = phrase.isEmpty ? nil : targetReader
        pendingFullTextPhrase = ""
        readerLocalFindState = targetReader.currentLocalFindState()
    }

    // MARK: - Sidebar Toggles & Thickness

    @objc func performSidebarToggle() {
        guard let item = librarySidebarItem else { return }
        let willCollapse = !item.isCollapsed
        if willCollapse {
            rememberSidebarThickness()
        }
        isSidebarHidden = willCollapse
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed = willCollapse
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
        if !willCollapse {
            restoreSidebarThickness(lastSidebarThickness)
        }
    }

    private func rememberSidebarThicknessIfVisible() {
        guard librarySidebarItem?.isCollapsed == false else { return }
        rememberSidebarThickness()
    }

    private func currentSidebarThickness() -> CGFloat {
        guard let sidebarView = librarySidebarItem?.viewController.view,
              !sidebarView.isHidden,
              sidebarView.frame.width > 0 else {
            return lastSidebarThickness
        }
        lastSidebarThickness = sidebarView.frame.width
        return sidebarView.frame.width
    }

    private func rememberSidebarThickness() {
        _ = currentSidebarThickness()
    }

    private func restoreSidebarThickness(_ thickness: CGFloat) {
        guard let librarySidebarItem,
              !librarySidebarItem.isCollapsed else { return }
        let clamped = min(max(thickness, librarySidebarItem.minimumThickness), librarySidebarItem.maximumThickness)
        lastSidebarThickness = clamped
        splitVC.splitView.setPosition(clamped, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.librarySidebarItem.isCollapsed else { return }
            self.splitVC.splitView.setPosition(clamped, ofDividerAt: 0)
            self.repairReaderSplitItems()
        }
    }

    @objc func performReaderSidebarToggle() {
        setReaderSidebarVisible(!(annotationsSidebarItem?.isCollapsed ?? true))
    }

    private func setReaderSidebarVisible(_ visible: Bool) {
        guard let item = annotationsSidebarItem else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed = !visible
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
        repairReaderSplitItems()
        toolbarState.isEmailReaderSidebarVisible = visible
    }

    @objc func showEmailAnnotationSidebar(_ sender: Any?) {
        readerSidebarMode = .annotations
        refreshReaderSidebar()
        setReaderSidebarVisible(true)
    }

    @objc func showTOCInEmailSidebar(_ sender: Any?) {
        readerSidebarMode = .tableOfContents
        refreshReaderSidebar()
        setReaderSidebarVisible(true)
    }

    private func repairReaderSplitItems() {
        guard let readerPaneItem, let annotationsSidebarItem else { return }
        readerPaneItem.isCollapsed = false
        readerPaneItem.canCollapse = false
        readerPaneItem.minimumThickness = 420

        annotationsSidebarItem.minimumThickness = 240
        annotationsSidebarItem.maximumThickness = 360
        annotationsSidebarItem.preferredThicknessFraction = 0.24

        guard splitVC.view.window != nil,
              !annotationsSidebarItem.isCollapsed,
              splitVC.splitView.bounds.width > 0 else { return }

        let splitWidth = splitVC.splitView.bounds.width
        let desiredAnnotationsWidth: CGFloat = 300
        let annotationsWidth = min(
            max(desiredAnnotationsWidth, annotationsSidebarItem.minimumThickness),
            annotationsSidebarItem.maximumThickness
        )
        let dividerIndex = splitVC.splitViewItems.count - 2
        guard dividerIndex >= 0 else { return }
        splitVC.splitView.setPosition(splitWidth - annotationsWidth, ofDividerAt: dividerIndex)
    }
}

// MARK: - FilterSheetCarrier

struct FilterSheetCarrier: View {
    let toolbarState: LibraryToolbarState
    let session: LibrarySession
    let displayController: LibraryDisplayController
    weak var emailVC: EmailLibraryViewController?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { toolbarState.showFilterDrawer },
                set: { toolbarState.showFilterDrawer = $0 }
            )) {
                FilterDrawerView(
                    expression: Binding(
                        get: { toolbarState.filterExpression },
                        set: { toolbarState.filterExpression = $0 }
                    ),
                    onApply: {
                        displayController.applyFilterRules()
                        toolbarState.showFilterDrawer = false
                    },
                    onClear: {
                        toolbarState.filterExpression = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        toolbarState.cancelLibraryFilterApplication()
                        displayController.scheduleLoadPage()
                        toolbarState.showFilterDrawer = false
                    }
                )
                .environment(toolbarState)
                .environment(session)
                .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showCollections },
                set: { toolbarState.showCollections = $0 }
            )) {
                let seedIDs = emailVC?.consumePendingCollectionSeedIDs() ?? []
                CollectionsView(calibreIDsToAdd: seedIDs, onSelectCollection: { collection in
                    displayController.addOrReplaceRule(FilterRule(field: .collection, op: .equals, value: collection.name))
                    toolbarState.showCollections = false
                })
                .environment(session)
                .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showReadingGoal },
                set: { toolbarState.showReadingGoal = $0 }
            )) {
                ReadingGoalView()
                    .environment(session)
                    .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
            .onChange(of: toolbarState.triggerExport) {
                if toolbarState.triggerExport {
                    ExportManager.presentExportPanel(
                        books: displayController.books,
                        session: session,
                        filterResult: toolbarState.activeFilterResult,
                        toolbarState: toolbarState
                    )
                    toolbarState.triggerExport = false
                }
            }
            .onChange(of: toolbarState.triggerAnnotationExport) {
                if toolbarState.triggerAnnotationExport {
                    AnnotationExportManager.presentExportPanel(session: session)
                    toolbarState.triggerAnnotationExport = false
                }
            }
            .onChange(of: toolbarState.triggerEPUBExport) {
                if toolbarState.triggerEPUBExport {
                    guard let libraryRoot = session.library?.root else { return }
                    Task {
                        let rows = await ExportManager.buildExportRows(
                            currentPageBooks: displayController.books,
                            session: session,
                            filterResult: toolbarState.activeFilterResult,
                            toolbarState: toolbarState
                        )
                        let ao3Map = LibraryQueryHelpers.indexed(rows.compactMap { row in
                            row.ao3.map { (row.book.id, $0) }
                        })
                        var seriesEntriesByBook: [Int: [SeriesCacheEntry]] = [:]
                        if toolbarState.groupBySeries, let metaDB = session.metaDB {
                            let ids = rows.map(\.book.id)
                            let currentAnthologyIDs = await session.library?.anthologyBookIDs() ?? []
                            if let entries = try? await metaDB.seriesEntries(for: ids) {
                                seriesEntriesByBook = Dictionary(grouping: entries.filter { !currentAnthologyIDs.contains($0.calibreID) }, by: \.calibreID)
                            }
                        }
                        ExportManager.presentEPUBExportPanel(
                            books: rows.map(\.book),
                            libraryRoot: libraryRoot,
                            ao3Map: ao3Map,
                            groupBySeries: toolbarState.groupBySeries,
                            seriesEntries: seriesEntriesByBook
                        )
                    }
                    toolbarState.triggerEPUBExport = false
                }
            }
    }
}

// MARK: - AmbrosiaEmailSplitViewController

final class AmbrosiaEmailSplitViewController: NSSplitViewController {

    var onDividerResize: (() -> Void)?

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex >= 0, dividerIndex < splitViewItems.count - 1 else { return proposedPosition }
        let leadingItem = splitViewItems[dividerIndex]
        guard !leadingItem.isCollapsed else { return proposedPosition }
        let leadingOrigin = splitView.subviews[dividerIndex].frame.minX
        let minPosition = leadingOrigin + leadingItem.minimumThickness
        let maxPosition = leadingOrigin + leadingItem.maximumThickness
        return min(max(proposedPosition, minPosition), maxPosition)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onDividerResize?()
    }
}
