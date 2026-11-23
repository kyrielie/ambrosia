import Foundation

enum TypographyValueFormat {
    /// Formats a numeric value as a clean string without unit.
    static func formatNumber(value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "0" }
        if fractionDigits == 0 {
            return "\(Int(value.rounded()))"
        } else {
            var text = String(format: "%.\(fractionDigits)f", value)
            if fractionDigits == 2 && text.hasSuffix("0") {
                text.removeLast()
            }
            return text
        }
    }

    /// Formats a numeric value for display with its unit outside or inline.
    static func format(value: Double, fractionDigits: Int, unit: String) -> String {
        let numStr = formatNumber(value: value, fractionDigits: fractionDigits)
        if unit.isEmpty {
            return numStr
        } else if unit == "px" {
            return "\(numStr)px"
        } else {
            return "\(numStr) \(unit)"
        }
    }

    /// Parses the first numeric value from a string, normalizing comma to period and ignoring surrounding text.
    static func parseNumber(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Scanner(string: normalized).scanDouble(), value.isFinite else { return nil }
        return value
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func roundedToDigits(_ value: Double, fractionDigits: Int) -> Double {
        let factor = pow(10.0, Double(max(0, fractionDigits)))
        return (value * factor).rounded() / factor
    }

    static func snap(_ value: Double, range: ClosedRange<Double>, step: Double, fractionDigits: Int) -> Double {
        guard value.isFinite, step > 0 else { return range.lowerBound }
        let steps = ((value - range.lowerBound) / step).rounded()
        let snapped = roundedToDigits(range.lowerBound + steps * step, fractionDigits: fractionDigits)
        return clamp(snapped, to: range)
    }
}
