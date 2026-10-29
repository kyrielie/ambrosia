import AppKit
import SwiftUI

// MARK: - FTS Search Results Window Controller

final class FTSSearchResultsWindowController: NSWindowController {

    static let shared = FTSSearchResultsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Search Library Body Text"
        window.minSize = NSSize(width: 550, height: 450)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AmbrosiaFTSSearchWindow")
        if !window.setFrameUsingName("AmbrosiaFTSSearchWindow") {
            window.center()
        }

        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: FTSSearchResultsView()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor
    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
