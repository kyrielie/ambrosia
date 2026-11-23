import SwiftUI
import AppKit

struct NativeStepperView: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSStepper {
        let stepper = NSStepper()
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.controlSize = .small
        stepper.target = context.coordinator
        stepper.action = #selector(Coordinator.stepperAction(_:))
        stepper.setContentHuggingPriority(.required, for: .horizontal)
        return stepper
    }

    func updateNSView(_ nsView: NSStepper, context: Context) {
        context.coordinator.parent = self
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        nsView.increment = step
        nsView.doubleValue = value
        nsView.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: NativeStepperView
        init(_ parent: NativeStepperView) {
            self.parent = parent
        }

        @objc func stepperAction(_ sender: NSStepper) {
            let snapped = TypographyValueFormat.snap(
                sender.doubleValue,
                range: parent.range,
                step: parent.step,
                fractionDigits: parent.fractionDigits
            )
            parent.value = snapped
        }
    }
}
