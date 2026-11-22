import SwiftUI
import AppKit

// MARK: - FilterRulePillView

struct FilterRulePillView: View {
    let rule: FilterRule
    let onRemove: () -> Void
    let onToggleNegation: () -> Void
    let onEditInDrawer: () -> Void
    let onClearAll: () -> Void

    private var isNegated: Bool {
        rule.op == .notContains || rule.op == .notEquals
    }

    private var accessibilityLabelText: String {
        let state = isNegated ? ", excluded" : ""
        if rule.value.isEmpty {
            return "\(rule.field.label)\(state)"
        }
        return "\(rule.field.label) \(rule.value)\(state)"
    }

    var body: some View {
        HStack(spacing: 3) {
            if isNegated {
                Text("NOT")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
            }
            Text(rule.field.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !rule.value.isEmpty {
                Text(rule.value)
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isNegated ? Color.red.opacity(0.7) : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove filter")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(isNegated ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                isNegated ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3),
                lineWidth: 0.5
            )
        )
        .contentShape(Capsule())
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove Filter", systemImage: "trash")
            }

            if rule.canToggleNegation {
                Button {
                    onToggleNegation()
                } label: {
                    if isNegated {
                        Label("Include This Filter", systemImage: "plus.circle")
                    } else {
                        Label("Exclude This Filter", systemImage: "minus.circle")
                    }
                }
            }

            if !rule.value.isEmpty {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(rule.value, forType: .string)
                } label: {
                    Label("Copy Filter Value", systemImage: "doc.on.doc")
                }
            }

            Button {
                onEditInDrawer()
            } label: {
                Label("Edit in Filter Drawer…", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(role: .destructive) {
                onClearAll()
            } label: {
                Label("Clear All Filters", systemImage: "xmark.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAction(named: "Remove Filter") {
            onRemove()
        }
    }
}

// MARK: - FullTextPillView

struct FullTextPillView: View {
    let phrase: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text("Full Text")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(phrase)
                .font(.caption2.bold())
                .lineLimit(1)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove full-text filter")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
        .contentShape(Capsule())
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove Full-Text Filter", systemImage: "trash")
            }

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(phrase, forType: .string)
            } label: {
                Label("Copy Search Phrase", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Full text: \(phrase)")
        .accessibilityAction(named: "Remove Full-Text Filter") {
            onRemove()
        }
    }
}

// MARK: - PendingFullTextPillView

struct PendingFullTextPillView: View {
    let phrase: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
            Text("Searching")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(phrase)
                .font(.caption2.bold())
                .lineLimit(1)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel search")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
        .contextMenu {
            Button(role: .destructive) {
                onCancel()
            } label: {
                Label("Cancel Search", systemImage: "xmark.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching full text for \(phrase)")
        .accessibilityAction(named: "Cancel Search") {
            onCancel()
        }
    }
}
