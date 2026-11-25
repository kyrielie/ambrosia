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

    let selectedText: String
    let onSave: (String?, AnnotationColor, String) -> Void   // (note?, colorKey, colorHex)
    let onCancel: () -> Void

    // MARK: - State

    @State private var noteText: String = ""
    @State private var colorKey: AnnotationColor = .yellow

    private var palette: HighlightPalette { ReaderPreferences.shared.highlightPalette }
    private var isDark: Bool { ReaderPreferences.shared.effectiveIsDark }

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

            // Cancel / Save
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") {
                    let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedHex = palette.hex(for: colorKey, isDark: isDark)
                    onSave(note.isEmpty ? nil : note, colorKey, resolvedHex)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
