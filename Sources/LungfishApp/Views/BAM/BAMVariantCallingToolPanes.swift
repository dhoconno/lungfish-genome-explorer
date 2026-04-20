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
                Toggle(
                    "This BAM has already been primer-trimmed for iVar.",
                    isOn: $state.ivarPrimerTrimConfirmed
                )

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

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness")
                .font(.headline)
            Text(state.readinessText)
                .foregroundStyle(.secondary)
        }
    }
}
