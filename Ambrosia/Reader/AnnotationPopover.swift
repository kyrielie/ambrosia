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
    let onSave:   (String?, String) -> Void   // (note?, colorHex)
    let onCancel: () -> Void

    // MARK: - State

    @State private var noteText:  String = ""
    @State private var colorHex: String = "#FFD60A"

    private let palette: [(label: String, hex: String)] = [
        ("Yellow",  "#FFD60A"),
        ("Red",     "#FF453A"),
        ("Green",   "#30D158"),
        ("Blue",    "#0A84FF"),
        ("Purple",  "#BF5AF2"),
    ]

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
                    ForEach(palette, id: \.hex) { swatch in
                        Button {
                            colorHex = swatch.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch.hex) ?? .yellow)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            colorHex == swatch.hex
                                                ? Color.primary : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.label)
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
                    onSave(note.isEmpty ? nil : note, colorHex)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Color hex helper (local to this file)

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
