import SwiftUI
import LungfishKit
import LungfishCore
import LungfishIO

struct GenotypeDropoutThresholdSection: View {
    @Binding var absoluteEnabled: Bool
    @Binding var absoluteValue: Int
    @Binding var sampleFractionEnabled: Bool
    @Binding var sampleFractionPercent: Double  // 0..100 for slider
    @Binding var locusFractionEnabled: Bool
    @Binding var locusFractionPercent: Double   // 0..100 for slider
    /// Per-locus EQ overrides keyed by locus name, percent (0..100).
    /// An entry overrides the global locus fraction; absent keys use the
    /// global slider. The "music EQ" model: an analyst can crank MHC-B up
    /// because it has many genes, while leaving MHC-DPB at the default.
    @Binding var perLocusFractionPercents: [String: Double]
    /// Loci to surface in the per-locus EQ grid. Order is preserved.
    var availableLoci: [String]
    var onApply: (GenotypeDropoutEvaluator) -> Void = { _ in }

    @State private var isPerLocusExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dropout thresholds")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("A diagnostic allele is marked low support if any active threshold is breached. Changes re-derive haplotype calls live.")
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
                    InlineNumericSliderField(
                        accessibilityTitle: "% of sample reads",
                        value: $sampleFractionPercent,
                        in: 0...10,
                        step: 0.05,
                        suffix: "%",
                        format: { String(format: "%.2f", $0) }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("% of locus reads", isOn: $locusFractionEnabled)
                    .font(.caption)
                if locusFractionEnabled {
                    InlineNumericSliderField(
                        accessibilityTitle: "% of locus reads",
                        value: $locusFractionPercent,
                        in: 0...10,
                        step: 0.1,
                        suffix: "%",
                        format: { String(format: "%.1f", $0) }
                    )
                    if !availableLoci.isEmpty {
                        DisclosureGroup(
                            "Per-locus EQ (\(perLocusFractionPercents.count) override\(perLocusFractionPercents.count == 1 ? "" : "s"))",
                            isExpanded: $isPerLocusExpanded
                        ) {
                            perLocusGrid
                                .padding(.top, 4)
                        }
                        .font(.caption2)
                    }
                }
            }

            Button("Apply thresholds") {
                onApply(currentEvaluator())
            }
            .controlSize(.small)
        }
    }

    /// Music-EQ-style grid: one row per locus, with a slider showing the
    /// locus-specific fraction. A small reset button removes the override
    /// so the locus falls back to the global setting. Disabled when the
    /// global locus-fraction toggle is off (then no thresholds apply at all).
    private var perLocusGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(availableLoci, id: \.self) { locus in
                HStack(spacing: 8) {
                    Text(locus)
                        .font(.caption2.monospaced())
                        .frame(width: 70, alignment: .leading)
                    let override = perLocusFractionPercents[locus]
                    let effective = override ?? locusFractionPercent
                    Slider(
                        value: Binding(
                            get: { effective },
                            set: { newValue in
                                // Drop the override when the analyst slides
                                // back onto the global value (within step
                                // granularity). Otherwise the override
                                // count would creep upward on every drag
                                // event and the reset button would stay
                                // armed on benign motions.
                                if abs(newValue - locusFractionPercent) < 0.05 {
                                    perLocusFractionPercents.removeValue(forKey: locus)
                                } else {
                                    perLocusFractionPercents[locus] = newValue
                                }
                            }
                        ),
                        in: 0...10,
                        step: 0.1
                    )
                    Text(String(format: "%.1f%%", effective))
                        .monospacedDigit()
                        .font(.caption2)
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(override != nil ? Color.accentColor : Color.secondary)
                    Button(action: { perLocusFractionPercents.removeValue(forKey: locus) }) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .opacity(override != nil ? 1.0 : 0.25)
                    .help(override != nil ? "Reset this locus to the global threshold." : "No override active.")
                }
            }
        }
    }

    private func currentEvaluator() -> GenotypeDropoutEvaluator {
        GenotypeDropoutEvaluator(
            absolute: absoluteEnabled ? absoluteValue : nil,
            sampleFraction: sampleFractionEnabled ? sampleFractionPercent / 100.0 : nil,
            locusFraction: locusFractionEnabled ? locusFractionPercent / 100.0 : nil,
            locusFractionOverrides: locusFractionEnabled
                ? perLocusFractionPercents.mapValues { $0 / 100.0 }
                : [:]
        )
    }
}
