import AppKit
import SwiftUI

class LibraryViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "Ambrosia — Library (stub)")
        label.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 740))
        view.addSubview(label)
    }
}
