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

            // Appearance Mode (System / Light / Dark)
            HStack {
                Text("Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Appearance Mode", selection: $prefs.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            // Theme swatches
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(ReaderTheme.allCases) { theme in
                        let isSelected = prefs.activeTheme == theme
                        let colors = theme.colorSet(for: prefs.effectiveIsDark)
                        Button {
                            prefs.applyTheme(theme)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: colors.background) ?? .white)
                                    .frame(width: 28, height: 28)
                                    .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)

                                Text("A")
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(Color(hex: colors.text) ?? .black)

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

            // Spacing & Typography Layout
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

                // Alignment (Left, Justify, Default)
                HStack {
                    Text("Alignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Alignment", selection: $prefs.textAlignment) {
                        Text("Left").tag(ThemeTextAlignment.left)
                        Text("Justified").tag(ThemeTextAlignment.justify)
                        Text("Default").tag(ThemeTextAlignment.book)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }

                // Paragraph Indent
                HStack {
                    Text("Paragraph Indent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Default", isOn: Binding(
                        get: { prefs.paragraphIndent == nil },
                        set: { isDef in prefs.paragraphIndent = isDef ? nil : 1.5 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    if let indent = prefs.paragraphIndent {
                        Slider(value: Binding(
                            get: { indent },
                            set: { prefs.paragraphIndent = $0 }
                        ), in: 0.5...3.0, step: 0.25)
                        .frame(width: 70)
                        Text(String(format: "%.2fem", indent))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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
