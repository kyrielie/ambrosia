import AppKit
import Observation
import SwiftUI

extension NSToolbarItem.Identifier {
    static let readerTOC        = NSToolbarItem.Identifier("ambrosia.reader.toc")
    static let readerSearch     = NSToolbarItem.Identifier("ambrosia.reader.search")
    static let readerNavigation = NSToolbarItem.Identifier("ambrosia.reader.navigation")
    static let readerLike       = NSToolbarItem.Identifier("ambrosia.reader.like")
    static let readerReadLater  = NSToolbarItem.Identifier("ambrosia.reader.readlater")
    static let readerAppearance = NSToolbarItem.Identifier("ambrosia.reader.appearance")
}

class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private let target: ReadingTarget
    private let book: CalibreBook
    /// Recorded when the window loads; diffed on close to accumulate reading time.
    private var sessionStartDate: Date = Date()
    private var didApplyInitialWindowSize = false
    /// True only while this controller itself is setting the window's frame
    /// (applyDefaultWindowSize), so windowDidResize can tell an AppKit-driven
    /// user resize apart from our own programmatic one and avoid feeding our
    /// own resize back into sessionWindowSize.
    private var isApplyingProgrammaticResize = false

    private static var openWindows: [String: ReaderWindowController] = [:]
    /// The size the user last resized a reader window to, shared across all
    /// books for the lifetime of the app process. Deliberately in-memory only
    /// (not UserDefaults-backed): a fresh launch always starts from the
    /// half-screen-portrait default, per product requirement. Reset to nil
    /// by resetAllToDefaultSize(), wired to the View menu's "Reset Reader
    /// Window Size to Default" command.
    private static var sessionWindowSize: NSSize?

    private static let toolbarSymbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    private(set) weak var readerViewController: ReaderViewController?
    private var appearancePopover: NSPopover?

    // Cached toolbar control views
    private var tocButton: NSButton?
    private var searchButton: NSButton?
    private var pageLabel: NSTextField?
    private var prevButton: NSButton?
    private var nextButton: NSButton?
    private var likeButton: NSButton?
    private var readLaterButton: NSButton?
    private var appearanceButton: NSButton?

    var tocButtonRef: NSButton? { tocButton }
    var searchButtonRef: NSButton? { searchButton }

    @MainActor
    static func open(book: CalibreBook) {
        open(target: .singleBook(book))
    }

    @MainActor
    static func open(target: ReadingTarget) {
        if let existing = openWindows[target.windowKey] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ReaderWindowController(target: target)
        openWindows[target.windowKey] = wc
        wc.showWindow(nil)
    }

    private init(target: ReadingTarget) {
        self.target = target
        self.book   = target.primaryBook

        // Create window with a placeholder size; actual size is set once the
        // window is actually shown (see the showWindow(_:) override below),
        // since window.screen is nil until then.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title   = target.displayTitle
        window.minSize = NSSize(width: 600, height: 500)
        window.isRestorable = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let vc = ReaderViewController(target: target)
        self.readerViewController = vc
        window.contentViewController = vc

        configureToolbar(window: window)

        vc.onReadingProgressChanged = { [weak self] in
            self?.updateToolbarState()
        }

        scheduleSessionObservation()
        updateToolbarState()

        // Update lastOpenedDate in BookState
        let calibreID = book.id
        Task {
            if let metaDB = AppDelegate.shared?.session.metaDB {
                try? await metaDB.markBookOpened(calibreID: calibreID)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func windowDidLoad() {
        super.windowDidLoad()
        sessionStartDate = Date()
    }

    // Sizing must happen here rather than in windowDidLoad(): this window is
    // constructed via super.init(window:) rather than loaded from a nib, so
    // AppKit considers it already "loaded" and never actually calls
    // windowDidLoad(). showWindow(_:) is the call site open() already uses to
    // display the window, and — critically — by the time super.showWindow(_:)
    // returns, the window has been ordered onto a real NSScreen, so
    // window.screen below is no longer nil. Previously the only call to
    // applyDefaultWindowSizeIfNeeded() ran in open(), before showWindow(nil),
    // when window.screen was always nil and sizing silently fell back to
    // NSScreen.main / NSScreen.screens[0] -- not reliably the screen the user
    // is actually working on (multi-monitor setups, docking/undocking, etc.).
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyDefaultWindowSizeIfNeeded()
        updateToolbarState()
    }

    private func applyDefaultWindowSizeIfNeeded() {
        guard !didApplyInitialWindowSize else { return }
        didApplyInitialWindowSize = true
        applyDefaultWindowSize()
    }

    /// Sizes a new reader window. If the user has already resized a reader
    /// window earlier in this session, every subsequently-opened book reuses
    /// that same size (Self.sessionWindowSize); otherwise this falls back to
    /// the half-screen-portrait default. Either way the result is centered
    /// on the target screen.
    private func applyDefaultWindowSize() {
        guard let window else { return }
        let screen  = window.screen ?? Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let size: NSSize
        if let remembered = Self.sessionWindowSize {
            size = remembered
        } else {
            let width  = (visible.width * 0.50).rounded()
            let height = (visible.height * 0.90).rounded()
            size = NSSize(width: width, height: height)
        }

        let x = visible.minX + (visible.width - size.width) / 2
        let y = visible.minY + (visible.height - size.height) / 2

        isApplyingProgrammaticResize = true
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        isApplyingProgrammaticResize = false
    }

    /// Wired to the View menu's "Reset Reader Window Size to Default"
    /// command via resetAllToDefaultSize(). Re-applies the half-screen-
    /// portrait formula to this specific window right now.
    @MainActor
    fileprivate func resetToDefaultSize() {
        applyDefaultWindowSize()
    }

    /// Clears the session-remembered size and immediately re-sizes every
    /// currently-open reader window back to the half-screen-portrait
    /// default. Called from the View menu.
    @MainActor
    static func resetAllToDefaultSize() {
        sessionWindowSize = nil
        for wc in openWindows.values {
            wc.resetToDefaultSize()
        }
    }

    /// Best-effort fallback for the rare case window.screen is still nil after
    /// showWindow(_:) returns (e.g. a screen was disconnected mid-launch).
    private static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    @MainActor
    func windowDidResize(_ notification: Notification) {
        guard didApplyInitialWindowSize, !isApplyingProgrammaticResize, let window else { return }
        Self.sessionWindowSize = window.frame.size
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeValue(forKey: target.windowKey)
        appearancePopover?.performClose(nil)
        appearancePopover = nil

        // Accumulate reading session time into BookState.totalReadingTimeSeconds
        let elapsed   = Date().timeIntervalSince(sessionStartDate)
        let calibreID = book.id
        Task {
            if let metaDB = AppDelegate.shared?.session.metaDB {
                try? await metaDB.addReadingTime(calibreID: calibreID, seconds: elapsed)
            }
        }
    }

    // MARK: - Toolbar Setup

    private func configureToolbar(window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ReaderWindowToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .readerTOC,
            .readerSearch,
            .flexibleSpace,
            .readerNavigation,
            .flexibleSpace,
            .readerLike,
            .readerReadLater,
            .readerAppearance
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .readerTOC,
            .readerSearch,
            .readerNavigation,
            .readerLike,
            .readerReadLater,
            .readerAppearance,
            .flexibleSpace,
            .space
        ]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .readerTOC:
            return makeTOCItem(identifier)

        case .readerSearch:
            return makeSearchItem(identifier)

        case .readerNavigation:
            return makeNavigationItem(identifier)

        case .readerLike:
            return makeLikeItem(identifier)

        case .readerReadLater:
            return makeReadLaterItem(identifier)

        case .readerAppearance:
            return makeAppearanceItem(identifier)

        default:
            return nil
        }
    }

    // MARK: - Item Builders

    private func makeIconItem(_ identifier: NSToolbarItem.Identifier,
                              label: String,
                              image: String,
                              action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: label)?
            .withSymbolConfiguration(Self.toolbarSymbolConfig)
        item.target = self
        item.action = action
        return item
    }

    private func makeNavigationItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Navigation"
        item.toolTip = "Previous / Next Page"

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY

        let prev = NSButton(
            image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Previous Page")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(prevPageClicked)
        )
        prev.bezelStyle = .accessoryBarAction
        prev.isBordered = false
        prev.toolTip = "Previous Page (Left Arrow / Shift-Space)"
        self.prevButton = prev

        let label = NSTextField(labelWithString: "1 / 1")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.pageLabel = label

        let next = NSButton(
            image: NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Next Page")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(nextPageClicked)
        )
        next.bezelStyle = .accessoryBarAction
        next.isBordered = false
        next.toolTip = "Next Page (Right Arrow / Space)"
        self.nextButton = next

        stack.addArrangedSubview(prev)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(next)

        item.view = stack
        return item
    }

    private func makeLikeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Like"
        item.toolTip = "Like this work"

        let button = NSButton(
            image: NSImage(systemSymbolName: "heart", accessibilityDescription: "Like")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(likeClicked)
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        self.likeButton = button

        item.view = button
        return item
    }

    private func makeReadLaterItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Read Later"
        item.toolTip = "Add to Read Later"

        let button = NSButton(
            image: NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Read Later")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(readLaterClicked)
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        self.readLaterButton = button

        item.view = button
        return item
    }

    private func makeAppearanceItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Appearance"
        item.toolTip = "Appearance (Aa)"

        let button = NSButton(
            image: NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Appearance")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(appearanceClicked(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        self.appearanceButton = button

        item.view = button
        return item
    }

    private func makeTOCItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Table of Contents"
        item.toolTip = "Table of Contents (⌘T)"

        let button = NSButton(
            image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Table of Contents")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(tocClicked(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        self.tocButton = button

        item.view = button
        return item
    }

    private func makeSearchItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Search in Book"
        item.toolTip = "Search in Book (⌘F)"

        let button = NSButton(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search in Book")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig) ?? NSImage(),
            target: self,
            action: #selector(searchClicked(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        self.searchButton = button

        item.view = button
        return item
    }

    // MARK: - Actions

    @objc private func tocClicked(_ sender: Any?) {
        readerViewController?.toggleTOCSidebar()
    }

    @objc private func searchClicked(_ sender: Any?) {
        readerViewController?.toggleSearchBar()
    }

    @objc private func prevPageClicked() {
        readerViewController?.goToPreviousPage()
    }

    @objc private func nextPageClicked() {
        readerViewController?.goToNextPage()
    }

    @objc private func likeClicked() {
        readerViewController?.toggleLikeCurrentWork(nil)
    }

    @objc private func readLaterClicked() {
        readerViewController?.toggleReadLaterCurrentWork(nil)
    }

    @objc private func appearanceClicked(_ sender: Any?) {
        guard let button = sender as? NSView else { return }
        if let popover = appearancePopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let popoverView = ReaderAppearancePopoverView(
            readerVC: readerViewController,
            onClose: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.appearancePopover = popover
    }

    // MARK: - State Updates

    @MainActor
    func updateToolbarState() {
        guard let readerVC = readerViewController else { return }

        let progress = readerVC.pageProgress
        pageLabel?.stringValue = progress.displayText
        prevButton?.isEnabled = readerVC.canGoPrevious
        nextButton?.isEnabled = readerVC.canGoNext

        guard let session = AppDelegate.shared?.session else { return }
        let calibreID = readerVC.activeCalibreID

        let isLiked = session.cachedLikedIDs.contains(calibreID)
        if let likeButton {
            let symbol = isLiked ? "heart.fill" : "heart"
            likeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Like")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig)
            likeButton.contentTintColor = isLiked ? .systemPink : nil
            likeButton.toolTip = isLiked ? "Liked (Click to unlike)" : "Like this work"
        }

        let isReadLater = session.cachedReadLaterIDs.contains(calibreID)
        if let readLaterButton {
            let symbol = isReadLater ? "bookmark.fill" : "bookmark"
            readLaterButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Read Later")?
                .withSymbolConfiguration(Self.toolbarSymbolConfig)
            readLaterButton.contentTintColor = isReadLater ? .systemOrange : nil
            readLaterButton.toolTip = isReadLater ? "In Read Later (Click to remove)" : "Add to Read Later"
        }
    }

    private func scheduleSessionObservation() {
        withObservationTracking {
            _ = AppDelegate.shared?.session.cachedLikedIDs
            _ = AppDelegate.shared?.session.cachedReadLaterIDs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateToolbarState()
                self?.scheduleSessionObservation()
            }
        }
    }
}
