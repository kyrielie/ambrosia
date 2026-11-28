import SwiftUI

// MARK: - AnnotationPopover
//
// SwiftUI view shown inside an NSPopover anchored to the WKWebView
// when "Add Annotation…" is chosen from the context menu.
//
// The caller (ReaderViewController.addAnnotationFromSelection) is
// responsible for:
//   1. Evaluating JS to get the selection (selectedText, startChar, endChar, spineIndex)
//   2. Creating an NSPopover containing NSHostingView<AnnotationPopover>
//   3. Passing an `onSave` closure that appends to bookState.annotations
//
// Width: 320 pt. NSPopover.behavior = .semitransient (set by caller).

struct AnnotationPopover: View {

    // MARK: - Input

    struct SavePayload {
        let note: String?
        let colorKey: AnnotationColor
        let colorHex: String
        let hasHighlight: Bool
        let replacementText: String?
    }

    let selectedText: String
    let allowTextEdit: Bool
    let onSave: (SavePayload) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var noteText: String
    @State private var colorKey: AnnotationColor
    @State private var hasHighlight: Bool
    @State private var replacementText: String
    @State private var showTextEditor: Bool

    private var palette: HighlightPalette { ReaderPreferences.shared.highlightPalette }
    private var isDark: Bool { ReaderPreferences.shared.effectiveIsDark }

    init(
        selectedText: String,
        initialNote: String? = nil,
        initialColorKey: AnnotationColor = .yellow,
        initialHasHighlight: Bool = true,
        initialReplacementText: String? = nil,
        allowTextEdit: Bool = true,
        onSave: @escaping (SavePayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedText = selectedText
        self.allowTextEdit = allowTextEdit
        self.onSave = onSave
        self.onCancel = onCancel
        _noteText = State(initialValue: initialNote ?? "")
        _colorKey = State(initialValue: initialColorKey)
        _hasHighlight = State(initialValue: initialHasHighlight)
        _replacementText = State(initialValue: initialReplacementText ?? selectedText)
        _showTextEditor = State(initialValue: initialReplacementText != nil)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Selected text preview
            if !selectedText.isEmpty {
                Text(selectedText.prefix(120).appending(selectedText.count > 120 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            // Note field
            VStack(alignment: .leading, spacing: 4) {
                Text("Note (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if noteText.isEmpty {
                        Text("Add a note…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .padding(.leading, 2)
                    }
                    TextEditor(text: $noteText)
                        .font(.body)
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }

            // Colour picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Highlight colour")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(AnnotationColor.allCases) { swatch in
                        Button {
                            colorKey = swatch
                        } label: {
                            Circle()
                                .fill(palette.swiftUIColor(for: swatch, isDark: isDark))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            colorKey == swatch
                                                ? Color.primary : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.displayName)
                    }
                    Spacer()
                }
            }

            // Non-destructive text edit (optional)
            if allowTextEdit && !selectedText.isEmpty {
                DisclosureGroup("Edit Text (Non-Destructive)", isExpanded: $showTextEditor) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Replacement text", text: $replacementText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        Toggle("Keep highlight", isOn: $hasHighlight)
                            .font(.caption)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Cancel / Save
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") {
                    let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedHex = palette.hex(for: colorKey, isDark: isDark)
                    let trimmedRepl = replacementText.trimmingCharacters(in: .newlines)
                    let editedText: String? = (showTextEditor && trimmedRepl != selectedText) ? trimmedRepl : nil
                    onSave(SavePayload(
                        note: note.isEmpty ? nil : note,
                        colorKey: colorKey,
                        colorHex: resolvedHex,
                        hasHighlight: editedText == nil ? true : hasHighlight,
                        replacementText: editedText
                    ))
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
