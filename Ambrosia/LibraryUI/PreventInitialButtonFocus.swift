import AppKit
import SwiftUI

// MARK: - PreventInitialButtonFocusModifier
//
// macOS 14 & 15 SwiftUI automatically focuses the first focusable control
// (usually the first button) in newly-opened sheets, panels, and windows,
// causing an unwanted focus ring / active highlight.
// This modifier removes that initial focus on appearance if the focused
// view is a button, while preserving keyboard focus if the user explicitly
// navigates via Tab.

struct PreventInitialButtonFocusModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible {
                    if let responder = window.firstResponder as? NSView,
                       responder is NSButton || String(describing: type(of: responder)).contains("Button") {
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
    }
}

extension View {
    func preventInitialButtonFocus() -> some View {
        modifier(PreventInitialButtonFocusModifier())
    }
}
