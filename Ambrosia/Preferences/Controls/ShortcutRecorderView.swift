import SwiftUI
import AppKit

/// A "click to record" control backed by a local NSEvent key-down monitor
/// while focused. Captures the next keystroke, hands it to the caller for
/// validation, and displays either the current binding or "Recording…"/an
/// unbound placeholder.
struct ShortcutRecorderView: NSViewRepresentable {
    var currentBinding: KeyBinding?
    var onRecord: (KeyBinding) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.updateTitle(binding: currentBinding)
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = onRecord
        nsView.updateTitle(binding: currentBinding)
    }

    final class RecorderButton: NSButton {
        var onRecord: ((KeyBinding) -> Void)?
        private var monitor: Any?
        private var isRecording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(startRecording)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func updateTitle(binding: KeyBinding?) {
            guard !isRecording else { return }
            title = binding?.displayString ?? "Click to set"
        }

        @objc private func startRecording() {
            guard !isRecording else { return }
            isRecording = true
            title = "Type shortcut…"

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                if event.keyCode == 53 { // Esc cancels
                    self.stopRecording()
                    return nil
                }

                if let binding = KeyBinding(event: event) {
                    self.stopRecording()
                    self.onRecord?(binding)
                    return nil
                }

                return event
            }
        }

        private func stopRecording() {
            isRecording = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
