import SwiftUI
import UniformTypeIdentifiers
import LungfishIO
import LungfishWorkflow

struct FASTQOperationToolPanes: View {
    @Bindable var state: FASTQOperationDialogState

    var body: some View {
        switch state.selectedToolID {
        case .minimap2, .bwaMem2, .bowtie2, .bbmap:
            MappingWizardSheet(
                inputFiles: state.selectedInputURLs,
                projectURL: state.projectURL,
                initialTool: state.selectedToolID.mappingTool ?? .minimap2,
                embeddedInOperationsDialog: true,
                embeddedRunTrigger: state.embeddedRunTrigger,
                onRun: state.captureMappingRequest(_:),
                onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
            )
            .id(state.selectedToolID.rawValue)
        case .spades, .megahit, .skesa, .flye, .hifiasm:
            AssemblyWizardSheet(
                inputFiles: state.selectedInputURLs,
                outputDirectory: state.outputDirectoryURL,
                initialTool: state.selectedToolID.assemblyTool ?? .spades,
                embeddedInOperationsDialog: true,
                embeddedRunTrigger: state.embeddedRunTrigger,
                onRun: state.captureAssemblyRequest(_:),
                onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
            )
            .id(state.selectedToolID.rawValue)
        case .kraken2:
            ClassificationWizardSheet(
                inputFiles: state.selectedInputURLs,
                embeddedInOperationsDialog: true,
                embeddedRunTrigger: state.embeddedRunTrigger,
                onRun: state.captureClassificationConfigs(_:),
                onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
            )
        case .esViritu:
            EsVirituWizardSheet(
                inputFiles: state.selectedInputURLs,
                embeddedInOperationsDialog: true,
                embeddedRunTrigger: state.embeddedRunTrigger,
                onRun: state.captureEsVirituConfigs(_:),
                onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
            )
        case .taxTriage:
            TaxTriageWizardSheet(
                initialFiles: state.selectedInputURLs,
                embeddedInOperationsDialog: true,
                embeddedRunTrigger: state.embeddedRunTrigger,
                onRun: state.captureTaxTriageConfig(_:),
                onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
            )
        default:
            derivativePane
        }
    }

    private func readinessHandler(for toolID: FASTQOperationToolID) -> (Bool) -> Void {
        { ready in
            state.updateEmbeddedReadiness(ready, for: toolID)
        }
    }

    private var derivativePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(DatasetOperationSection.overview.title) {
                    Text(state.selectedToolSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if state.visibleSections.contains(.inputs) {
                    section(state.inputSectionTitle) {
                        FASTQOperationInputsSection(state: state)
                    }
                }

                if state.visibleSections.contains(.primarySettings) {
                    section(DatasetOperationSection.primarySettings.title) {
                        FASTQOperationPrimarySettingsSection(state: state)
                    }
                }

                if state.visibleSections.contains(.advancedSettings) {
                    section(DatasetOperationSection.advancedSettings.title) {
                        FASTQOperationAdvancedSettingsSection(state: state)
                    }
                }

                if state.visibleSections.contains(.output) {
                    section(state.outputSectionTitle) {
                        Picker("Output Strategy", selection: $state.outputMode) {
                            ForEach(state.outputStrategyOptions, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if state.visibleSections.contains(.readiness) {
                    section(DatasetOperationSection.readiness.title) {
                        Text(state.readinessText)
                            .font(.callout)
                            .foregroundStyle(state.isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FASTQOperationInputsSection: View {
    @Bindable var state: FASTQOperationDialogState
    @State private var browsingInputKind: FASTQOperationInputKind?
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.datasetLabel, systemImage: "doc.text")
                .font(.body)

            ForEach(state.requiredInputKinds.filter { $0 != .fastqDataset }, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.subheadline.weight(.medium))
                            Text(inputSummary(for: kind))
                                .font(.caption)
                                .foregroundStyle(inputSummaryColor(for: kind))
                        }

                        Spacer()

                        Button(state.auxiliaryInputURL(for: kind) == nil ? "Choose…" : "Replace…") {
                            browsingInputKind = kind
                            isImporterPresented = true
                        }

                        if state.auxiliaryInputURL(for: kind) != nil {
                            Button("Clear") {
                                state.removeAuxiliaryInput(for: kind)
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            defer { browsingInputKind = nil }
            guard let browsingInputKind else { return }
            guard case .success(let urls) = result, let url = urls.first else { return }
            state.setAuxiliaryInput(url, for: browsingInputKind)
        }
    }

    private func inputSummary(for kind: FASTQOperationInputKind) -> String {
        guard let url = state.auxiliaryInputURL(for: kind) else {
            return "Required before this tool can run."
        }

        guard state.isAuxiliaryInputValid(for: kind) else {
            return "\(url.lastPathComponent) is not a valid \(kind.title.lowercased())."
        }

        return url.lastPathComponent
    }

    private func inputSummaryColor(for kind: FASTQOperationInputKind) -> Color {
        state.auxiliaryInputURL(for: kind) != nil && !state.isAuxiliaryInputValid(for: kind)
            ? Color.lungfishOrangeFallback
            : .secondary
    }
}

private struct FASTQOperationPrimarySettingsSection: View {
    @Bindable var state: FASTQOperationDialogState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.selectedToolID {
            case .refreshQCSummary:
                Text("No additional primary settings are required for this QC summary refresh.")
                    .foregroundStyle(.secondary)

            case .qualityTrim:
                labeledTextField("Threshold", text: Self.intBinding(state, \.qualityTrimThreshold))
                labeledTextField("Window Size", text: Self.intBinding(state, \.qualityTrimWindowSize))
                Picker("Mode", selection: $state.qualityTrimMode) {
                    ForEach(FASTQQualityTrimMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

            case .adapterRemoval:
                Picker("Adapter Mode", selection: $state.adapterRemovalMode) {
                    Text("Auto-Detect").tag(FASTQAdapterMode.autoDetect)
                    Text("Manual Sequence").tag(FASTQAdapterMode.specified)
                }
                .pickerStyle(.segmented)
                if state.adapterRemovalMode == .specified {
                    labeledTextField("Adapter Sequence", text: $state.adapterRemovalSequence)
                }

            case .primerTrimming:
                Picker("Primer Source", selection: $state.primerTrimmingSource) {
                    Text("Literal Sequence").tag(FASTQPrimerSource.literal)
                    Text("Reference FASTA").tag(FASTQPrimerSource.reference)
                }
                .pickerStyle(.segmented)
                if state.primerTrimmingSource == .literal {
                    labeledTextField("Primer Sequence", text: $state.primerTrimmingLiteralSequence)
                } else {
                    Text("Select the primer reference FASTA in the Inputs section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    labeledCompactTextField("k", text: Self.intBinding(state, \.primerTrimmingKmerSize))
                    labeledCompactTextField("mink", text: Self.intBinding(state, \.primerTrimmingMinKmer))
                    labeledCompactTextField("hdist", text: Self.intBinding(state, \.primerTrimmingHammingDistance))
                }

            case .trimFixedBases:
                HStack(spacing: 12) {
                    labeledCompactTextField("5' Trim", text: Self.intBinding(state, \.trimFixedBasesFrom5Prime))
                    labeledCompactTextField("3' Trim", text: Self.intBinding(state, \.trimFixedBasesFrom3Prime))
                }

            case .filterByReadLength:
                HStack(spacing: 12) {
                    labeledCompactTextField("Min Length", text: Self.optionalIntBinding(state, \.filterByReadLengthMin))
                    labeledCompactTextField("Max Length", text: Self.optionalIntBinding(state, \.filterByReadLengthMax))
                }

            case .removeContaminants:
                Picker("Contaminant Mode", selection: $state.removeContaminantsMode) {
                    Text("PhiX").tag(FASTQContaminantFilterMode.phix)
                    Text("Custom Reference").tag(FASTQContaminantFilterMode.custom)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    labeledCompactTextField("K-mer", text: Self.intBinding(state, \.removeContaminantsKmerSize))
                    labeledCompactTextField("Hamming Distance", text: Self.intBinding(state, \.removeContaminantsHammingDistance))
                }
                if state.removeContaminantsMode == .custom {
                    Text("Select the contaminant reference FASTA in the Inputs section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .removeDuplicates:
                Picker("Preset", selection: $state.removeDuplicatesPreset) {
                    ForEach(FASTQDeduplicatePreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                if state.removeDuplicatesPreset == .custom {
                    labeledCompactTextField("Substitutions", text: Self.intBinding(state, \.removeDuplicatesSubstitutions))
                    Toggle("Optical Duplicates", isOn: $state.removeDuplicatesOptical)
                    if state.removeDuplicatesOptical {
                        labeledCompactTextField("Optical Distance", text: Self.intBinding(state, \.removeDuplicatesOpticalDistance))
                    }
                }

            case .mergeOverlappingPairs:
                Picker("Strictness", selection: $state.mergeOverlappingPairsStrictness) {
                    Text("Normal").tag(FASTQMergeStrictness.normal)
                    Text("Strict").tag(FASTQMergeStrictness.strict)
                }
                .pickerStyle(.segmented)
                labeledCompactTextField("Minimum Overlap", text: Self.intBinding(state, \.mergeOverlappingPairsMinOverlap))

            case .repairPairedEndFiles:
                Text("No additional settings are required for paired-end repair.")
                    .foregroundStyle(.secondary)

            case .reverseComplement:
                Text("No additional settings are required for reverse complement.")
                    .foregroundStyle(.secondary)

            case .translate:
                Text("Frame 1 translation is used for this operation.")
                    .foregroundStyle(.secondary)

            case .orientReads:
                labeledCompactTextField("Word Length", text: Self.intBinding(state, \.orientWordLength))
                Picker("Database Mask", selection: $state.orientDbMask) {
                    Text("dust").tag("dust")
                    Text("none").tag("none")
                }
                .pickerStyle(.segmented)
                Text("Select a reference sequence in the Inputs section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .correctSequencingErrors:
                labeledCompactTextField("K-mer Size", text: Self.intBinding(state, \.correctSequencingErrorsKmerSize))

            case .subsampleByProportion:
                labeledCompactTextField("Proportion", text: Self.optionalDoubleBinding(state, \.subsampleByProportionValue))

            case .subsampleByCount:
                labeledCompactTextField("Count", text: Self.optionalIntBinding(state, \.subsampleByCountValue))

            case .extractReadsByID:
                labeledTextField("Query", text: $state.extractReadsByIDQuery)
                Picker("Field", selection: $state.extractReadsByIDField) {
                    Text("ID").tag(FASTQSearchField.id)
                    Text("Description").tag(FASTQSearchField.description)
                }
                .pickerStyle(.segmented)
                Toggle("Use Regular Expression", isOn: $state.extractReadsByIDRegex)

            case .extractReadsByMotif:
                labeledTextField("Pattern", text: $state.extractReadsByMotifPattern)
                Toggle("Use Regular Expression", isOn: $state.extractReadsByMotifRegex)

            case .selectReadsBySequence:
                labeledTextField("Sequence or FASTA Path", text: $state.selectReadsBySequenceValue)
                Picker("Search End", selection: $state.selectReadsBySequenceSearchEnd) {
                    Text("5' End").tag(FASTQAdapterSearchEnd.fivePrime)
                    Text("3' End").tag(FASTQAdapterSearchEnd.threePrime)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    labeledCompactTextField("Min Overlap", text: Self.intBinding(state, \.selectReadsBySequenceMinOverlap))
                    labeledCompactTextField("Error Rate", text: Self.doubleBinding(state, \.selectReadsBySequenceErrorRate))
                }
                Toggle("Keep Matched Reads", isOn: $state.selectReadsBySequenceKeepMatched)
                Toggle("Search Reverse Complement", isOn: $state.selectReadsBySequenceSearchReverseComplement)

            case .demultiplexBarcodes:
                Picker("Barcode Source", selection: $state.demultiplexBarcodeSource) {
                    Text("Built-In Kit").tag(FASTQDemultiplexBarcodeSource.builtinKit)
                    Text("Custom Definition").tag(FASTQDemultiplexBarcodeSource.customDefinition)
                }
                .pickerStyle(.segmented)
                if state.demultiplexBarcodeSource == .builtinKit {
                    Picker("Built-In Kit", selection: $state.demultiplexKitID) {
                        ForEach(BarcodeKitRegistry.builtinKits()) { kit in
                            Text(kit.displayName).tag(kit.id)
                        }
                    }
                } else {
                    Text("Select the barcode definition CSV in the Inputs section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Location", selection: $state.demultiplexLocation) {
                    Text("Both Ends").tag("bothends")
                    Text("5' End").tag("fiveprime")
                    Text("3' End").tag("threeprime")
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    labeledCompactTextField("5' Distance", text: Self.intBinding(state, \.demultiplexMaxDistanceFrom5Prime))
                    labeledCompactTextField("3' Distance", text: Self.intBinding(state, \.demultiplexMaxDistanceFrom3Prime))
                }
                HStack(spacing: 12) {
                    labeledCompactTextField("Error Rate", text: Self.doubleBinding(state, \.demultiplexErrorRate))
                    Toggle("Trim Barcodes", isOn: $state.demultiplexTrimBarcodes)
                }

            case .removeHumanReads, .minimap2, .bwaMem2, .bowtie2, .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2, .esViritu, .taxTriage:
                Text("This tool uses the dedicated embedded workflow pane or the fixed database chooser above.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 180, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledCompactTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
    }

    private static func intBinding(_ state: FASTQOperationDialogState, _ keyPath: WritableKeyPath<FASTQOperationDialogState, Int>) -> Binding<String> {
        Binding(
            get: { String(state[keyPath: keyPath]) },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(trimmed) {
                    var mutableState = state
                    mutableState[keyPath: keyPath] = value
                }
            }
        )
    }

    private static func optionalIntBinding(_ state: FASTQOperationDialogState, _ keyPath: WritableKeyPath<FASTQOperationDialogState, Int?>) -> Binding<String> {
        Binding(
            get: { state[keyPath: keyPath].map { String($0) } ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var mutableState = state
                mutableState[keyPath: keyPath] = Int(trimmed)
            }
        )
    }

    private static func optionalDoubleBinding(_ state: FASTQOperationDialogState, _ keyPath: WritableKeyPath<FASTQOperationDialogState, Double?>) -> Binding<String> {
        Binding(
            get: { state[keyPath: keyPath].map { String($0) } ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var mutableState = state
                mutableState[keyPath: keyPath] = trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }

    private static func doubleBinding(_ state: FASTQOperationDialogState, _ keyPath: WritableKeyPath<FASTQOperationDialogState, Double>) -> Binding<String> {
        Binding(
            get: { String(state[keyPath: keyPath]) },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(trimmed) {
                    var mutableState = state
                    mutableState[keyPath: keyPath] = value
                }
            }
        )
    }
}

private struct FASTQOperationAdvancedSettingsSection: View {
    @Bindable var state: FASTQOperationDialogState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.selectedToolID {
            case .qualityTrim:
                Text("Quality trimming uses the selected threshold, window size, and mode.")
                    .foregroundStyle(.secondary)
            case .adapterRemoval:
                Text("Manual adapter trimming only exposes a single literal sequence in this slice.")
                    .foregroundStyle(.secondary)
            case .primerTrimming:
                Text("Primer trimming is constrained to the CLI-supported bbduk subset.")
                    .foregroundStyle(.secondary)
            case .trimFixedBases:
                Text("Trim values are applied exactly as entered.")
                    .foregroundStyle(.secondary)
            case .filterByReadLength:
                Text("Length filtering will use the entered minimum and maximum bounds.")
                    .foregroundStyle(.secondary)
            case .removeContaminants:
                Text("Custom contaminant mode expects the reference FASTA in the Inputs section.")
                    .foregroundStyle(.secondary)
            case .removeDuplicates:
                Text("The deduplication preset selects the CLI-compatible parameter set.")
                    .foregroundStyle(.secondary)
            case .mergeOverlappingPairs:
                Text("Merge strictness only affects the bbmerge invocation.")
                    .foregroundStyle(.secondary)
            case .repairPairedEndFiles:
                Text("Paired-end repair has no additional settings.")
                    .foregroundStyle(.secondary)
            case .reverseComplement:
                Text("Reverse complement preserves FASTQ quality scores by reversing them with the sequence.")
                    .foregroundStyle(.secondary)
            case .translate:
                Text("Translation emits FASTA output because amino-acid sequences do not have nucleotide quality scores.")
                    .foregroundStyle(.secondary)
            case .orientReads:
                Text("Orient reads against the selected reference sequence without saving a separate unoriented bundle.")
                    .foregroundStyle(.secondary)
            case .correctSequencingErrors:
                Text("The k-mer size controls Tadpole error correction.")
                    .foregroundStyle(.secondary)
            case .subsampleByProportion, .subsampleByCount:
                Text("Subsampling settings are taken directly from the values entered above.")
                    .foregroundStyle(.secondary)
            case .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence:
                Text("Search and sequence filtering use the literal values entered above.")
                    .foregroundStyle(.secondary)
            case .demultiplexBarcodes:
                Text("Demultiplexing uses either a built-in kit or a custom barcode definition from the Inputs section.")
                    .foregroundStyle(.secondary)
            case .removeHumanReads:
                Text("Human read removal stays fixed to the selected database input.")
                    .foregroundStyle(.secondary)
            case .refreshQCSummary, .minimap2, .bwaMem2, .bowtie2, .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2, .esViritu, .taxTriage:
                Text("This tool uses the embedded workflow pane.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension FASTQOperationOutputMode {
    var title: String {
        switch self {
        case .perInput:
            return "Per Input"
        case .groupedResult:
            return "Grouped Result"
        case .fixedBatch:
            return "Batch Output"
        }
    }
}

private extension FASTQQualityTrimMode {
    var displayName: String {
        switch self {
        case .cutRight:
            return "Cut Right"
        case .cutFront:
            return "Cut Front"
        case .cutTail:
            return "Cut Tail"
        case .cutBoth:
            return "Cut Both"
        }
    }
}

private extension FASTQDeduplicatePreset {
    var displayName: String {
        switch self {
        case .exactPCR:
            return "Exact PCR"
        case .nearDuplicate1:
            return "Near Duplicate 1"
        case .nearDuplicate2:
            return "Near Duplicate 2"
        case .opticalHiSeq:
            return "Optical HiSeq"
        case .opticalNovaSeq:
            return "Optical NovaSeq"
        case .custom:
            return "Custom"
        }
    }
}
