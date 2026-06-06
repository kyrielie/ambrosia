import AppKit
import SwiftUI
import SwiftData

class LibraryViewController: NSViewController {
    private let modelContainer: ModelContainer
    private let session: LibrarySession

    init(modelContainer: ModelContainer, session: LibrarySession) {
        self.modelContainer = modelContainer
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let rootView = LibraryRootView()
            .modelContainer(modelContainer)
            .environment(session)
        let hosting = NSHostingView(rootView: rootView)
        view = hosting
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
    }
}
