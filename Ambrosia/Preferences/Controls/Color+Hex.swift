import SwiftUI
import AppKit

extension Color {
    init?(hex: String) {
        var normalized = hex.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("#") { normalized = String(normalized.dropFirst()) }
        if normalized.count == 3 { normalized = normalized.map { "\($0)\($0)" }.joined() }
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue: Double( value        & 0xFF) / 255
        )
    }

    var hexString: String? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = NSColor(self).cgColor.converted(
                to: sRGB,
                intent: .defaultIntent, options: nil),
              let components = cg.components, components.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(components[0]*255), Int(components[1]*255), Int(components[2]*255))
    }
}
