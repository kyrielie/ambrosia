// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class IngestionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _cancelled = true
    }
}

@MainActor
final class ImportProgressWindowController: NSWindowController {

    private let titleLabel = NSTextField(labelWithString: "Setting Up Library…")
    private let statusLabel = NSTextField(labelWithString: "Discovering EPUB files…")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var cancellation = IngestionCancellation()
    private var onCompletion: ((Bool) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let window = self.window else { return }
        window.title = "Ambrosia"

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.isIndeterminate = true
        progressBar.style = .bar
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(progressBar)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    @objc private func cancelTapped() {
        cancellation.cancel()
        cancelButton.isEnabled = false
        statusLabel.stringValue = "Cancelling…"
    }

    /// Starts the ingestion workflow for a folder of EPUBs.
    public func startIngestion(
        folderURL: URL,
        epubs: [DiscoveredEPUB],
        createDB: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        self.onCompletion = completion
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(epubs.count, 1))
        progressBar.doubleValue = 0

        let token = self.cancellation
        Task.detached(priority: .userInitiated) { [weak self] in
            let isCancelledClosure = { () -> Bool in
                token.isCancelled
            }

            // Step 1: Create empty DB if requested
            if createDB {
                await MainActor.run {
                    self?.titleLabel.stringValue = "Creating Library Database…"
                    self?.statusLabel.stringValue = "Initializing Calibre schema…"
                }
                do {
                    try CalibreLibraryCreator.createEmptyLibrary(at: folderURL, overwrite: false)
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(error)
                        self?.close()
                        completion(false)
                    }
                    return
                }
            }

            // Step 2: Metadata Extraction & DB insertion
            await MainActor.run {
                self?.titleLabel.stringValue = "Extracting Metadata…"
                self?.progressBar.maxValue = Double(epubs.count)
                self?.progressBar.doubleValue = 0
            }

            _ = try? CalibreLibraryWriter.importEPUBs(
                epubs: epubs,
                into: folderURL,
                batchSize: 25,
                progress: { [weak self] info in
                    Task { @MainActor [weak self] in
                        self?.progressBar.doubleValue = Double(info.current)
                        self?.statusLabel.stringValue = "(\(info.current)/\(info.total)) \(info.currentTitle)"
                    }
                },
                isCancelled: isCancelledClosure
            )

            if token.isCancelled {
                await MainActor.run {
                    self?.close()
                    completion(false)
                }
                return
            }

            // Step 3: FTS Indexing
            await MainActor.run {
                self?.titleLabel.stringValue = "Building Full-Text Search…"
                self?.statusLabel.stringValue = "Indexing book text for instant search…"
                self?.progressBar.doubleValue = 0
            }

            _ = try? CalibreFTSWriter.indexLibrary(
                at: folderURL,
                batchSize: 10,
                progress: { [weak self] info in
                    Task { @MainActor [weak self] in
                        self?.progressBar.doubleValue = Double(info.current)
                        self?.statusLabel.stringValue = "(\(info.current)/\(info.total)) \(info.currentTitle)"
                    }
                },
                isCancelled: isCancelledClosure
            )

            await MainActor.run { [weak self] in
                let wasCancelled = token.isCancelled
                self?.close()
                completion(!wasCancelled)
            }
        }
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Library Setup Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
