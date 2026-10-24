import AppKit
import SwiftUI

struct ReaderAppearancePopoverView: View {
    @Bindable private var prefs = ReaderPreferences.shared
    weak var readerVC: ReaderViewController?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header / Mode switch
            HStack {
                Text("Appearance")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: Binding(
                    get: { readerVC?.currentMode ?? prefs.defaultReadingMode },
                    set: { newMode in
                        readerVC?.setReadingMode(newMode)
                        prefs.defaultReadingMode = newMode
                    }
                )) {
                    Label("Paged", systemImage: "book.pages").tag(ReadingMode.paginated)
                    Label("Scroll", systemImage: "scroll").tag(ReadingMode.scroll)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            Divider()

            // Theme swatches
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(ReaderTheme.allCases) { theme in
                        let isSelected = prefs.activeTheme == theme
                        Button {
                            prefs.applyTheme(theme)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: theme.bg) ?? .white)
                                    .frame(width: 28, height: 28)
                                    .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)

                                Text("A")
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(Color(hex: theme.fg) ?? .black)

                                if isSelected {
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: 2.5)
                                        .frame(width: 34, height: 34)
                                } else {
                                    Circle()
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .help(theme.label)
                    }
                }
            }

            Divider()

            // Font size & Font family
            VStack(alignment: .leading, spacing: 10) {
                // Font size stepper
                HStack {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            prefs.decreaseFontSize()
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(prefs.fontSize <= 10)

                        Text("\(prefs.fontSize) pt")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(minWidth: 44, alignment: .center)

                        Button {
                            prefs.increaseFontSize()
                        } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(prefs.fontSize >= 36)

                        if prefs.fontSize != ReaderPreferences.Defaults.fontSize {
                            Button("Reset") {
                                prefs.resetFontSize()
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                            .padding(.leading, 2)
                        }
                    }
                }

                // Font family picker
                HStack {
                    Text("Font")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $prefs.fontFamily) {
                        ForEach(ReaderPreferences.fontPresets, id: \.id) { preset in
                            Text(preset.label).tag(preset.cssStack)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }

            Divider()

            // Spacing & Layout
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Line Spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Slider(value: $prefs.lineHeight, in: 1.2...2.2, step: 0.1)
                        .frame(width: 130)
                    Text(String(format: "%.1f", prefs.lineHeight))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                if (readerVC?.currentMode ?? prefs.defaultReadingMode) == .paginated {
                    HStack {
                        Text("Columns")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Columns", selection: $prefs.colsPerScreen) {
                            Text("1 Column").tag(ColsPerScreen.one)
                            Text("2 Columns").tag(ColsPerScreen.two)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            }

            Divider()

            // Footer: Preferences link
            HStack {
                Spacer()
                Button("All Reader Settings…") {
                    onClose?()
                    PreferencesWindowController.show()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
