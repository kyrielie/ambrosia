import SwiftUI
import AppKit

final class NativeNumericAppKitTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            DispatchQueue.main.async { [weak self] in
                self?.currentEditor()?.selectAll(nil)
            }
        }
        return result
    }
}

struct NativeNumericTextField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    var disabledText: String?
    var isEnabled: Bool = true
    var width: CGFloat = 58

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NativeNumericAppKitTextField {
        let textField = NativeNumericAppKitTextField()
        textField.isBordered = true
        textField.bezelStyle = .squareBezel
        textField.focusRingType = .default
        textField.font = .systemFont(ofSize: 11, weight: .regular)
        textField.alignment = .center
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.textDidCommit(_:))
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.setContentHuggingPriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        return textField
    }

    func updateNSView(_ nsView: NativeNumericAppKitTextField, context: Context) {
        context.coordinator.parent = self

        if !isEnabled, let disabledText {
            nsView.stringValue = disabledText
            nsView.textColor = .disabledControlTextColor
            nsView.isEditable = false
            nsView.isEnabled = false
            return
        }

        nsView.isEnabled = true
        nsView.isEditable = true
        nsView.textColor = .controlTextColor

        if !context.coordinator.isEditing {
            let formatted = TypographyValueFormat.formatNumber(value: value, fractionDigits: fractionDigits)
            if nsView.stringValue != formatted {
                nsView.stringValue = formatted
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeNumericTextField
        var isEditing = false

        init(_ parent: NativeNumericTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let textField = obj.object as? NSTextField else { return }
            commitText(textField.stringValue)
        }

        @objc func textDidCommit(_ sender: NSTextField) {
            commitText(sender.stringValue)
        }

        private func commitText(_ text: String) {
            if let parsed = TypographyValueFormat.parseNumber(text) {
                let snapped = TypographyValueFormat.snap(
                    parsed,
                    range: parent.range,
                    step: parent.step,
                    fractionDigits: parent.fractionDigits
                )
                parent.value = snapped
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ReaderTypographyDidChange"),
                object: nil
            )
        }
    }
}
