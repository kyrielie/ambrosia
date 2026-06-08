import SwiftUI

// MARK: - FindBarView
//
// Thin find-in-page bar shown at the bottom of the reader window.
// Opened with ⌘F, closed with Escape or the × button.
// Communicates upward via callbacks; the actual WKWebView.find() call
// is made by ReaderViewController to keep WebKit access in one place.

struct FindBarView: View {

    @Binding var searchText: String
    let matchCurrent: Int    // 1-based current match index (0 = no match yet)
    let matchTotal:   Int    // total matches found (0 = no results / not searched yet)
    let onNext:       () -> Void
    let onPrevious:   () -> Void
    let onClose:      () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("Find…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 160)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            )

            // Match counter
            if !searchText.isEmpty {
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(matchTotal == 0 ? .red : .secondary)
                    .frame(minWidth: 52, alignment: .leading)
            }

            // Previous / Next
            HStack(spacing: 2) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(matchTotal == 0)
                .help("Previous match (⇧⌘G)")

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(matchTotal == 0)
                .help("Next match (⌘G)")
            }

            Spacer()

            // Close
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Escape)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var matchLabel: String {
        if matchTotal == 0 { return "No results" }
        if matchCurrent == 0 { return "\(matchTotal) found" }
        return "\(matchCurrent) of \(matchTotal)"
    }
}
