import SwiftUI
import Observation
import LungfishKit
import LungfishWorkflow

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
                .lungfishHelp(LungfishHelpContent.bamVariantAlignmentTrack)

                TextField("Output Variant Track Name", text: $state.outputTrackName)
                    .textFieldStyle(.roundedBorder)
                    .lungfishHelp(LungfishHelpContent.bamVariantOutputTrack)
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
                        .lungfishHelp(LungfishHelpContent.bamVariantThresholds)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Minimum Depth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("10", text: $state.minimumDepthText)
                        .textFieldStyle(.roundedBorder)
                        .lungfishHelp(LungfishHelpContent.bamVariantThresholds)
                }
            }
        }
    }

    @ViewBuilder
    private var callerSpecificSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(state.selectedToolDisplayName) Settings")
                .font(.headline)

            if state.selectedToolID == BAMVariantCallingToolID.gatkHaplotypeCaller.rawValue {
                Text("GATK HaplotypeCaller will write a standard genotype VCF for the selected BAM.")
                    .foregroundStyle(.secondary)
            } else if state.selectedToolID == BAMVariantCallingToolID.gatkWhatsHapPhased.rawValue {
                Text("GATK HaplotypeCaller and WhatsHap will be assembled as a phase-aware command plan.")
                    .foregroundStyle(.secondary)
            } else {
                switch state.selectedCaller {
            case .lofreq:
                Text("LoFreq is ready to run directly on the selected bundle alignment track.")
                    .foregroundStyle(.secondary)

            case .bcftools:
                Text("bcftools will run mpileup and call as an orthogonal cross-check on the selected BAM.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Ploidy", selection: $state.ploidy) {
                        ForEach(VariantCallingPloidy.allCases, id: \.self) { ploidy in
                            Text(ploidy.displayName).tag(ploidy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .lungfishHelp(LungfishHelpContent.bamVariantPloidy)
                    Text(state.inferredPloidy.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .ivar:
                if let auto = state.autoConfirmedPrimerTrim {
                    Toggle(
                        "This BAM has already been primer-trimmed for iVar.",
                        isOn: .constant(true)
                    )
                    .disabled(true)
                    .lungfishHelp(LungfishHelpContent.bamVariantIvarPrimerTrim)
                    Text("Primer-trimmed by Lungfish on \(state.autoConfirmedDateString(auto.timestamp)) using \(auto.primerScheme.bundleName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        "This BAM has already been primer-trimmed for iVar.",
                        isOn: $state.ivarPrimerTrimConfirmed
                    )
                    .lungfishHelp(LungfishHelpContent.bamVariantIvarPrimerTrim)
                }

            case .medaka:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Medaka Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("r1041_e82_400bps_sup_variant_v5.0.0", text: $state.medakaModel)
                        .textFieldStyle(.roundedBorder)
                        .lungfishHelp(LungfishHelpContent.bamVariantOntModel)
                    Text("A medaka variant model named for the pore, instrument and basecaller, such as r941_prom_sup_variant_g507.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .clair3:
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Sequencing Platform", selection: $state.sequencingPlatform) {
                        Text("Automatic (from read groups)")
                            .tag(Optional<VariantCallingPlatform>.none)
                        ForEach(VariantCallingPlatform.allCases, id: \.self) { platform in
                            Text(platform.displayName)
                                .tag(Optional(platform))
                        }
                    }
                    .pickerStyle(.menu)
                    .lungfishHelp(LungfishHelpContent.bamVariantSequencingPlatform)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clair3 Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Platform default", text: $state.medakaModel)
                            .textFieldStyle(.roundedBorder)
                            .lungfishHelp(LungfishHelpContent.bamVariantOntModel)
                        Text("Leave empty for the model Clair3 ships for the platform, or name one, such as r941_prom_sup_g5014, or give a model folder path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                }
            }
        }
    }

    private var advancedOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extra arguments")
                .font(.headline)

            TextField("--call-indels", text: $state.advancedOptionsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lungfishHelp(LungfishHelpContent.fastqAdvancedArguments)
        }
    }

    @ViewBuilder
    private var ivarOptionsSection: some View {
        if state.selectedToolID == BAMVariantCallingToolID.ivar.rawValue {
            VStack(alignment: .leading, spacing: 12) {
                Text("iVar Options")
                    .font(.headline)

                HStack {
                    Text("Consensus allele frequency")
                    Spacer()
                    TextField("0.75", value: $state.ivarConsensusAF, format: .number)
                        .frame(width: 70)
                        .lungfishHelp(LungfishHelpContent.bamVariantIvarConsensusAF)
                }
                HStack {
                    Text("Merge AF distance")
                    Spacer()
                    TextField("0.25", value: $state.ivarMergeAFThreshold, format: .number)
                        .frame(width: 70)
                        .lungfishHelp(LungfishHelpContent.bamVariantIvarMergeAF)
                }
                HStack {
                    Text("Minimum ALT quality")
                    Spacer()
                    TextField("20", value: $state.ivarBadQualityThreshold, format: .number)
                        .frame(width: 70)
                        .lungfishHelp(LungfishHelpContent.bamVariantIvarBadQuality)
                }
                Toggle(
                    "Ignore strand bias (recommended for amplicons)",
                    isOn: $state.ivarIgnoreStrandBias
                )
                .lungfishHelp(LungfishHelpContent.bamVariantIvarStrandBias)
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness")
                .font(.headline)
            Text(state.readinessText)
                .foregroundStyle(.secondary)
                .lungfishHelp(LungfishHelpContent.operationReadiness)
        }
    }
}
