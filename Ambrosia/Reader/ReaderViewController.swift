import AppKit
import WebKit
import SwiftData
import ZIPFoundation

class ReaderViewController: NSViewController {

    let book: CalibreBook
    let modelContainer: ModelContainer
    private var webView: WKWebView!

    init(book: CalibreBook, modelContainer: ModelContainer) {
        self.book           = book
        self.modelContainer = modelContainer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.isTextInteractionEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadFirstSpineItem()
    }

    private func loadFirstSpineItem() {
        // Use libraryRoot from LibraryRegistry (session not accessible from here without DI)
        guard let pathStr = LibraryRegistry.shared.activePath else {
            showError("No library open."); return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
              FileManager.default.fileExists(atPath: epubURL.path) else {
            showError("EPUB file not found for: \(book.displayTitle)")
            return
        }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let html = try EPUBLoader.loadFirstSpineHTML(from: epubURL)
                await MainActor.run { _ = self.webView.loadHTMLString(html, baseURL: nil) }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    private func showError(_ message: String) {
        let html = """
        <html><body style="font-family:system-ui;color:#999;padding:40px;text-align:center">
        <p style="font-size:48px">📖</p><p>\(message)</p>
        </body></html>
        """
        _ = webView.loadHTMLString(html, baseURL: nil)
    }
}
