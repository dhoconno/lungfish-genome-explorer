import SwiftUI
import LungfishCore
import LungfishIO

struct GenotypeDropoutThresholdSection: View {
    @Binding var absoluteEnabled: Bool
    @Binding var absoluteValue: Int
    @Binding var sampleFractionEnabled: Bool
    @Binding var sampleFractionPercent: Double  // 0..100 for slider
    @Binding var locusFractionEnabled: Bool
    @Binding var locusFractionPercent: Double   // 0..100 for slider
    var onApply: (GenotypeDropoutEvaluator) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dropout thresholds")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("A diagnostic allele is marked low support if any active threshold is breached.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Absolute reads", isOn: $absoluteEnabled)
                    .font(.caption)
                if absoluteEnabled {
                    HStack {
                        Stepper("\(absoluteValue) reads",
                                value: $absoluteValue,
                                in: 1...10_000,
                                step: 10)
                            .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("% of sample reads", isOn: $sampleFractionEnabled)
                    .font(.caption)
                if sampleFractionEnabled {
                    HStack {
                        Slider(value: $sampleFractionPercent, in: 0...10, step: 0.05)
                        Text(String(format: "%.2f%%", sampleFractionPercent))
                            .monospacedDigit()
                            .font(.caption)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("% of locus reads", isOn: $locusFractionEnabled)
                    .font(.caption)
                if locusFractionEnabled {
                    HStack {
                        Slider(value: $locusFractionPercent, in: 0...50, step: 0.5)
                        Text(String(format: "%.1f%%", locusFractionPercent))
                            .monospacedDigit()
                            .font(.caption)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }

            Button("Apply thresholds") {
                onApply(currentEvaluator())
            }
            .controlSize(.small)
        }
    }

    private func currentEvaluator() -> GenotypeDropoutEvaluator {
        GenotypeDropoutEvaluator(
            absolute: absoluteEnabled ? absoluteValue : nil,
            sampleFraction: sampleFractionEnabled ? sampleFractionPercent / 100.0 : nil,
            locusFraction: locusFractionEnabled ? locusFractionPercent / 100.0 : nil
        )
    }
}
