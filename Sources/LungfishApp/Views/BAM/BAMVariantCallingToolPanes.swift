import SwiftUI
import Observation

struct BAMVariantCallingToolPanes: View {
    @Bindable var state: BAMVariantCallingDialogState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewSection
                thresholdsSection
                callerSpecificSection
                ivarOptionsSection
                advancedOptionsSection
                readinessSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.headline)

            if state.alignmentTrackOptions.isEmpty {
                Text("No alignment tracks are available in this bundle.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Alignment Track", selection: $state.selectedAlignmentTrackID) {
                    ForEach(state.alignmentTrackOptions, id: \.id) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .pickerStyle(.menu)

                TextField("Output Variant Track Name", text: $state.outputTrackName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thresholds")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Minimum Allele Frequency")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0.05", text: $state.minimumAlleleFrequencyText)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Minimum Depth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("10", text: $state.minimumDepthText)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    @ViewBuilder
    private var callerSpecificSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(state.selectedCaller.displayName) Settings")
                .font(.headline)

            switch state.selectedCaller {
            case .lofreq:
                Text("LoFreq is ready to run directly on the selected bundle alignment track.")
                    .foregroundStyle(.secondary)

            case .ivar:
                if let auto = state.autoConfirmedPrimerTrim {
                    Toggle(
                        "This BAM has already been primer-trimmed for iVar.",
                        isOn: .constant(true)
                    )
                    .disabled(true)
                    Text("Primer-trimmed by Lungfish on \(state.autoConfirmedDateString(auto.timestamp)) using \(auto.primerScheme.bundleName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        "This BAM has already been primer-trimmed for iVar.",
                        isOn: $state.ivarPrimerTrimConfirmed
                    )
                }

            case .medaka:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Medaka Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("r1041_e82_400bps_sup_v5.0.0", text: $state.medakaModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var advancedOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Options")
                .font(.headline)

            TextField("--call-indels", text: $state.advancedOptionsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private var ivarOptionsSection: some View {
        if state.selectedCaller == .ivar {
            VStack(alignment: .leading, spacing: 12) {
                Text("iVar Options")
                    .font(.headline)

                HStack {
                    Text("Consensus allele frequency")
                    Spacer()
                    TextField("0.75", value: $state.ivarConsensusAF, format: .number)
                        .frame(width: 70)
                }
                HStack {
                    Text("Merge AF distance")
                    Spacer()
                    TextField("0.25", value: $state.ivarMergeAFThreshold, format: .number)
                        .frame(width: 70)
                }
                HStack {
                    Text("Minimum ALT quality")
                    Spacer()
                    TextField("20", value: $state.ivarBadQualityThreshold, format: .number)
                        .frame(width: 70)
                }
                Toggle(
                    "Ignore strand bias (recommended for amplicons)",
                    isOn: $state.ivarIgnoreStrandBias
                )
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness")
                .font(.headline)
            Text(state.readinessText)
                .foregroundStyle(.secondary)
        }
    }
}
