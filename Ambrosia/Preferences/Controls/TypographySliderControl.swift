import SwiftUI

struct TypographySliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let unit: String
    var disabledText: String?
    var isEnabled: Bool = true
    var fieldWidth: CGFloat = 58
    var defaultValue: Double?
    var accessibilityLabel: String = ""

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int = 1,
        unit: String = "",
        disabledText: String? = nil,
        isEnabled: Bool = true,
        fieldWidth: CGFloat = 58,
        defaultValue: Double? = nil,
        accessibilityLabel: String = ""
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.fractionDigits = fractionDigits
        self.unit = unit
        self.disabledText = disabledText
        self.isEnabled = isEnabled
        self.fieldWidth = fieldWidth
        self.defaultValue = defaultValue
        self.accessibilityLabel = accessibilityLabel
    }

    init(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String = "",
        disabledText: String? = nil,
        isEnabled: Bool = true,
        fieldWidth: CGFloat = 58,
        defaultValue: Double? = nil,
        accessibilityLabel: String = ""
    ) {
        self._value = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        self.fractionDigits = 0
        self.unit = unit
        self.disabledText = disabledText
        self.isEnabled = isEnabled
        self.fieldWidth = fieldWidth
        self.defaultValue = defaultValue
        self.accessibilityLabel = accessibilityLabel
    }

    private var canReset: Bool {
        guard isEnabled, let defaultValue else { return false }
        return abs(value - defaultValue) > 0.001
    }

    var body: some View {
        HStack(spacing: 5) {
            Slider(value: Binding(
                get: { value },
                set: { raw in
                    value = TypographyValueFormat.snap(raw, range: range, step: step, fractionDigits: fractionDigits)
                }
            ), in: range)
            .accessibilityLabel(accessibilityLabel)
            .disabled(!isEnabled)

            // Native AppKit squareBezel text field showing only the raw number (spacious 58pt x 22pt)
            NativeNumericTextField(
                value: $value,
                range: range,
                step: step,
                fractionDigits: fractionDigits,
                disabledText: disabledText,
                isEnabled: isEnabled,
                width: fieldWidth
            )
            .frame(width: fieldWidth, height: 22)

            // Native AppKit up/down stepper arrows
            NativeStepperView(
                value: $value,
                range: range,
                step: step,
                fractionDigits: fractionDigits,
                isEnabled: isEnabled
            )
            .frame(width: 13, height: 22)

            // Unit placed cleanly OUTSIDE the box
            Text(isEnabled ? unit : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            // Inline reset button (circular counterclockwise arrow)
            Button {
                if let defaultValue {
                    value = defaultValue
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canReset ? Color.secondary : Color.clear)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
            .disabled(!canReset)
            .help(canReset ? "Reset to default" : "")
        }
    }
}
