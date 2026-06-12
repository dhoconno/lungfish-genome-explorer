import AppKit
import LungfishIO
import LungfishWorkflow
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowOperationsDialog: View {
    @Bindable var state: WorkflowOperationDialogState
    let onRun: (WorkflowOperationLaunchRequest) -> Void
    let onCreateTwelveSReferenceBundle: (TwelveSReferenceBundleBuildConfiguration) -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: "Workflow Operations",
            subtitle: "Run enabled specialized and user workflows.",
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            accessibilityNamespace: "workflow-operations",
            onSelectTool: state.selectTool(_:),
            onCancel: { NSApp.keyWindow?.close() },
            onRun: runSelectedWorkflow
        ) {
            WorkflowOperationsDetailPane(
                state: state,
                onCreateTwelveSReferenceBundle: onCreateTwelveSReferenceBundle
            )
        }
        .alert(
            "Workflow Operation Error",
            isPresented: $state.showingError,
            presenting: state.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func runSelectedWorkflow() {
        do {
            onRun(try state.makeLaunchRequest())
        } catch {
            state.errorMessage = error.localizedDescription
            state.showingError = true
        }
    }
}

private struct WorkflowOperationsDetailPane: View {
    @Bindable var state: WorkflowOperationDialogState
    let onCreateTwelveSReferenceBundle: (TwelveSReferenceBundleBuildConfiguration) -> Void
    @State private var showingReferencePanel = false
    @State private var showingBarcodePanel = false
    @State private var showingOutputPanel = false
    @State private var showingTwelveSReferenceBuilder = false
    @State private var twelveSReferenceDraft = TwelveSReferenceBundleDraft()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(DatasetOperationSection.overview.title) {
                    Text(state.selectedToolSummary)
                        .foregroundStyle(.secondary)
                }

                section(DatasetOperationSection.inputs.title) {
                    referencePicker
                    if case .ontGenotyping = state.selectedTool?.kind,
                       state.effectiveGenotypingMode == .ontBarcodeDemux {
                        barcodePicker
                    }
                    if case .twelveSAmpliconMatching = state.selectedTool?.kind {
                        twelveSSampleMetadataPicker
                    }
                    readPicker
                }

                section(DatasetOperationSection.primarySettings.title) {
                    primarySettings
                }

                section(DatasetOperationSection.advancedSettings.title) {
                    advancedSettings
                }

                section(DatasetOperationSection.output.title) {
                    outputPicker
                }

                section(DatasetOperationSection.readiness.title) {
                    Text(state.readinessText)
                        .font(.callout)
                        .foregroundStyle(state.isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showingTwelveSReferenceBuilder) {
            TwelveSReferenceBundleBuilderSheet(
                projectURL: state.projectURL,
                draft: $twelveSReferenceDraft,
                onCancel: {
                    showingTwelveSReferenceBuilder = false
                },
                onCreate: { configuration in
                    showingTwelveSReferenceBuilder = false
                    onCreateTwelveSReferenceBundle(configuration)
                }
            )
        }
    }

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Reference")
            if !state.projectReferenceCandidates.isEmpty {
                Picker("Project Reference", selection: referenceBinding) {
                    Text("Choose reference").tag(URL?.none)
                    ForEach(state.projectReferenceCandidates, id: \.self) { url in
                        Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: state.projectURL))
                            .tag(URL?.some(url))
                    }
                }
                .pickerStyle(.menu)
            }
            HStack(spacing: 10) {
                Text(state.selectedReferenceDisplay)
                    .font(.caption)
                    .foregroundStyle(state.selectedReferenceURL == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                if case .twelveSAmpliconMatching = state.selectedTool?.kind {
                    Button("Create 12S Reference\u{2026}") {
                        twelveSReferenceDraft = TwelveSReferenceBundleDraft(projectURL: state.projectURL)
                        showingTwelveSReferenceBuilder = true
                    }
                }
                Button(state.selectedReferenceURL == nil ? "Choose…" : "Replace…") {
                    browseForReference()
                }
                if state.selectedReferenceURL != nil {
                    Button("Clear") {
                        state.setReference(nil)
                    }
                }
            }
        }
    }

    private var readPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("FASTQ Bundles")
            Text(state.selectedReadsDisplay)
                .font(.caption)
                .foregroundStyle(state.selectedReadURLs.isEmpty ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                .lineLimit(3)
                .accessibilityIdentifier("workflow-operations-resolved-input-summary")
            if let folderEmptyNoticeText = state.folderEmptyNoticeText {
                helperText(folderEmptyNoticeText)
            }
            if let folderSubfolderNoticeText = state.folderSubfolderNoticeText {
                helperText(folderSubfolderNoticeText)
                Toggle(
                    "Include subfolders",
                    isOn: Binding(
                        get: { state.includeSubfolderBundles },
                        set: { state.setIncludeSubfolderBundles($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("workflow-operations-include-subfolders")
                helperText("When enabled, all eligible bundles in descendant folders are added to this batch.")
                    .accessibilityIdentifier("workflow-operations-include-subfolders-help")
            }
            if let folderDuplicateNoticeText = state.folderDuplicateNoticeText {
                helperText(folderDuplicateNoticeText)
            }
            if state.resolvedReadDetailRows.count > 1 {
                DisclosureGroup("Resolved inputs") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.resolvedReadDetailRows, id: \.url) { row in
                            Text(row.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
                .accessibilityIdentifier("workflow-operations-resolved-input-details")
            }
        }
    }

    private var barcodePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Barcode Definition")
            if !state.projectBarcodeDefinitionCandidates.isEmpty {
                Picker("Project File", selection: barcodeDefinitionProjectFileBinding) {
                    Text("Choose project file").tag(URL?.none)
                    ForEach(state.projectBarcodeDefinitionCandidates, id: \.self) { url in
                        Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: state.projectURL))
                            .tag(URL?.some(url))
                    }
                }
                .pickerStyle(.menu)
            }
            HStack(spacing: 10) {
                Text(state.selectedBarcodeDefinitionURL.map {
                    WorkflowOperationDialogState.displayPath(for: $0, relativeTo: state.projectURL)
                } ?? "No barcode definition selected")
                .font(.caption)
                .foregroundStyle(state.selectedBarcodeDefinitionURL == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                .lineLimit(2)
                Spacer()
                Button(state.selectedBarcodeDefinitionURL == nil ? "Choose…" : "Replace…") {
                    browseForBarcodeDefinition()
                }
                if state.selectedBarcodeDefinitionURL != nil {
                    Button("Clear") {
                        state.setBarcodeDefinition(nil)
                    }
                }
            }
        }
    }

    private var twelveSSampleMetadataPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Analysis Metadata")
            HStack(spacing: 10) {
                Text(state.twelveSSampleMetadataDisplay)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button(state.twelveSSampleMetadataURL == nil ? "Choose Metadata\u{2026}" : "Replace Metadata\u{2026}") {
                    browseForTwelveSSampleMetadata()
                }
                if state.twelveSSampleMetadataURL != nil {
                    Button("Clear") {
                        state.setTwelveSSampleMetadata(nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var primarySettings: some View {
        switch state.selectedTool?.kind {
        case .ontGenotyping:
            VStack(alignment: .leading, spacing: 12) {
                workflowFormGroup("Report") {
                    labeledTextField("Report Name", text: $state.outputName)
                }
                workflowFormGroup("Run Parameters") {
                    genotypingModePicker
                    HStack(spacing: 12) {
                        labeledCompactTextField("Threads", value: $state.threads)
                        labeledCompactTextField("Min Reads", value: $state.minSupport)
                    }
                }
                workflowFormGroup("Call Thresholds") {
                    labeledCompactDoubleTextField("Locus %", value: $state.haplotypeDropoutLocusPercent)
                    helperText("Used for haplotype calls and Excel output. Inspector filters only change what is shown.")
                }
                haplotypeDefinitionPicker
            }
        case .fullLengthONTMHCGenotyping:
            VStack(alignment: .leading, spacing: 12) {
                workflowFormGroup("Report") {
                    labeledTextField("Report Name", text: $state.outputName)
                }
                workflowFormGroup("Run Parameters") {
                    labeledCompactTextField("Threads", value: $state.threads)
                }
                workflowFormGroup("Length Filter") {
                    HStack(spacing: 12) {
                        labeledCompactTextField("Min Length", value: $state.fullLengthMinimumLength)
                        labeledCompactTextField("Max Length", value: $state.fullLengthMaximumLength)
                    }
                }
                workflowFormGroup("Call Thresholds") {
                    labeledCompactDoubleTextField("Locus %", value: $state.haplotypeDropoutLocusPercent)
                    helperText("Used for haplotype calls and Excel output. Inspector filters only change what is shown.")
                }
                haplotypeDefinitionPicker
            }
        case .twelveSAmpliconMatching:
            VStack(alignment: .leading, spacing: 10) {
                twelveSMatchingModePicker
                labeledTextField("Result Name", text: $state.outputName)
                labeledCompactTextField("Min Soft Clip", value: $state.twelveSMinimumSoftClipBases)
            }
        case .workflowPackage(let package):
            VStack(alignment: .leading, spacing: 8) {
                labeledTextField("Output Name", text: $state.outputName)
                labeledCompactTextField("Cores", value: $state.threads)
                Text("\(package.manifest.runner.kind.rawValue.capitalized) package, version \(package.manifest.version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            Text("No runnable workflow selected.")
                .foregroundStyle(.secondary)
        }
    }

    private var twelveSMatchingModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Read Platform")
            Picker("Read Platform", selection: twelveSMatchingModeBinding) {
                ForEach(TwelveSAmpliconMatchingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workflow-operations-twelve-s-matching-mode")
        }
    }

    private var genotypingModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Read Type")
            Picker("Read Type", selection: genotypingReadTypeBinding) {
                ForEach(AmpliconGenotypingReadType.allCases, id: \.rawValue) { readType in
                    Text(readType.displayName).tag(readType.rawValue)
                }
            }
            .pickerStyle(.menu)
            Text(state.effectiveGenotypingMode.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var haplotypeDefinitionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                groupLabel("Haplotype Definition")
                Spacer()
                Button("Manage\u{2026}") {
                    NSApp.sendAction(#selector(ToolsMenuActions.showHaplotypeDefinitions(_:)), to: nil, from: nil)
                }
                .controlSize(.small)
            }
            if state.usesBundledHaplotypeDefinitions {
                bundledHaplotypeSummary
            } else {
                haplotypeDefinitionPickerStack
            }
        }
    }

    @ViewBuilder
    private var bundledHaplotypeSummary: some View {
        HStack {
            Text(state.referenceBundleSummary ?? "From selected MHC reference bundle")
                .foregroundStyle(.secondary)
            Spacer()
        }
        Text("This bundle pairs its own haplotype definition with the reference FASTA.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var haplotypeDefinitionPickerStack: some View {
        Picker("Assay", selection: haplotypeAssayBinding) {
            Text("Choose assay").tag("")
            ForEach(haplotypeAssayOptions, id: \.id) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        Picker("Species", selection: haplotypeSpeciesBinding) {
            Text("Any species").tag("")
            ForEach(haplotypeSpeciesOptions, id: \.code) { option in
                Text(option.label).tag(option.code)
            }
        }
        .pickerStyle(.menu)
        Picker("Definition", selection: haplotypeDefinitionBinding) {
            Text("No haplotyping").tag("")
            ForEach(haplotypeDefinitionOptions, id: \.id) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        Text("Deterministic haplotyping runs only when a definition is selected.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var advancedSettings: some View {
        switch state.selectedTool?.kind {
        case .ontGenotyping:
            DisclosureGroup("Advanced Options", isExpanded: $state.advancedOptionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    labeledTextField("minimap2 arguments", text: $state.extraArgumentsText)
                    Text("Arguments are passed to minimap2 after the ONT mapping preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        case .fullLengthONTMHCGenotyping:
            DisclosureGroup("Advanced Options", isExpanded: $state.advancedOptionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    fullLengthPrimerRow(
                        title: "Orient Reference",
                        url: state.fullLengthOrientReferenceURL,
                        set: { state.fullLengthOrientReferenceURL = $0 }
                    )
                    fullLengthPrimerRow(
                        title: "Forward Primers",
                        url: state.fullLengthForwardPrimerURL,
                        set: { state.fullLengthForwardPrimerURL = $0 }
                    )
                    fullLengthPrimerRow(
                        title: "Reverse Primers",
                        url: state.fullLengthReversePrimerURL,
                        set: { state.fullLengthReversePrimerURL = $0 }
                    )
                }
                .padding(.top, 4)
            }
        case .twelveSAmpliconMatching:
            DisclosureGroup("Advanced Options", isExpanded: $state.advancedOptionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    labeledCompactTextField("Max Indels", value: $state.twelveSMaximumIndelBases)
                        .disabled(state.twelveSMatchingMode != .ontIndel)
                    Toggle("Run vsearch chimera review", isOn: $state.twelveSRunChimeraReview)
                    Text("The 12S workflow expects merged FASTQ inputs; paired-read merging should be handled before import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        case .workflowPackage(let package):
            VStack(alignment: .leading, spacing: 6) {
                Text("Inputs: \(package.manifest.inputs.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Outputs: \(package.manifest.outputs.map(\.pathTemplate).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Runtime: \(package.manifest.runtime.kind.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            EmptyView()
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("Directory")
            HStack(spacing: 10) {
                Text(state.outputDirectoryDisplay)
                    .font(.caption)
                    .foregroundStyle(state.outputDirectoryURL == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button(state.outputDirectoryURL == nil ? "Choose…" : "Replace…") {
                    browseForOutputDirectory()
                }
            }
        }
    }

    private var referenceBinding: Binding<URL?> {
        Binding(
            get: { state.selectedReferenceURL },
            set: { state.setReference($0) }
        )
    }

    private var barcodeDefinitionProjectFileBinding: Binding<URL?> {
        Binding(
            get: {
                guard let selected = state.selectedBarcodeDefinitionURL,
                      state.projectBarcodeDefinitionCandidates.contains(selected) else {
                    return nil
                }
                return selected
            },
            set: { state.setBarcodeDefinition($0) }
        )
    }

    private var haplotypeDefinitionBinding: Binding<String> {
        Binding(
            get: { state.selectedHaplotypeDefinitionSetID ?? "" },
            set: { state.setHaplotypeDefinition($0.isEmpty ? nil : $0) }
        )
    }

    private var genotypingReadTypeBinding: Binding<String> {
        Binding(
            get: { state.selectedGenotypingReadType.rawValue },
            set: { value in
                if let readType = AmpliconGenotypingReadType(cliArgument: value) {
                    state.selectedGenotypingReadType = readType
                }
            }
        )
    }

    private var twelveSMatchingModeBinding: Binding<String> {
        Binding(
            get: { state.twelveSMatchingMode.rawValue },
            set: { value in
                if let mode = TwelveSAmpliconMatchingMode.cliValue(value) {
                    state.twelveSMatchingMode = mode
                }
            }
        )
    }

    private var haplotypeAssayBinding: Binding<String> {
        Binding(
            get: { state.selectedHaplotypeAssayID ?? "" },
            set: { state.setHaplotypeAssay($0.isEmpty ? nil : $0) }
        )
    }

    private var haplotypeSpeciesBinding: Binding<String> {
        Binding(
            get: { state.selectedHaplotypeSpeciesCode ?? "" },
            set: { state.setHaplotypeSpecies($0.isEmpty ? nil : $0) }
        )
    }

    private var haplotypeAssayOptions: [(id: String, label: String)] {
        state.haplotypeDefinitionRegistry.assays.map { assay in
            (id: assay.id, label: assay.displayName)
        }
    }

    private var haplotypeDefinitionOptions: [(id: String, label: String)] {
        state.compatibleHaplotypeDefinitionRecords.map { record in
            let definitionSet = record.definitionSet
            return (
                id: definitionSet.id,
                label: "\(definitionSet.displayName) (\(definitionSet.speciesCode), \(record.sourceDisplayName))"
            )
        }
    }

    private var haplotypeSpeciesOptions: [(code: String, label: String)] {
        state.haplotypeSpeciesOptions
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workflowFormGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupLabel(_ label: String) -> some View {
        Text(label)
            .font(.subheadline.weight(.medium))
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func helperText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func labeledCompactTextField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .labelsHidden()
        }
    }

    private func labeledCompactDoubleTextField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .labelsHidden()
        }
    }

    private func fullLengthPrimerRow(
        title: String,
        url: URL?,
        set: @escaping (URL?) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                groupLabel(title)
                Text(url.map { WorkflowOperationDialogState.displayPath(for: $0, relativeTo: state.projectURL) } ?? "None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(url == nil ? "Choose…" : "Replace…") {
                browseForFASTA(title: "Choose \(title)", completion: set)
            }
            if url != nil {
                Button("Clear") {
                    set(nil)
                }
            }
        }
    }

    private func browseForReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference"
        panel.message = "Select a .lungfishref bundle or FASTA file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setReference(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func browseForFASTA(title: String, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Select a FASTA file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = []
        for ext in ["fa", "fasta", "fna", "fas"] {
            if let type = UTType(filenameExtension: ext) {
                contentTypes.append(type)
            }
        }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            completion(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func browseForBarcodeDefinition() {
        let panel = NSOpenPanel()
        panel.title = "Choose Barcode Definition"
        panel.message = "Select a CSV, TSV, or text file containing sample names and barcodes."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.plainText]
        if let csv = UTType(filenameExtension: "csv") {
            contentTypes.append(csv)
        }
        if let tsv = UTType(filenameExtension: "tsv") {
            contentTypes.append(tsv)
        }
        panel.allowedContentTypes = contentTypes
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setBarcodeDefinition(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func browseForTwelveSSampleMetadata() {
        let panel = NSOpenPanel()
        panel.title = "Choose Analysis Metadata"
        panel.message = "Select a CSV or TSV file with sample metadata to use when this analysis runs."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.plainText]
        if let csv = UTType(filenameExtension: "csv") {
            contentTypes.append(csv)
        }
        if let tsv = UTType(filenameExtension: "tsv") {
            contentTypes.append(tsv)
        }
        panel.allowedContentTypes = contentTypes
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setTwelveSSampleMetadata(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func browseForOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setOutputDirectory(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

private struct TwelveSReferenceBundleDraft: Equatable {
    var name: String = ""
    var deduplicatedFASTA: URL?
    var midoriMetadataTSV: URL?
    var outputURL: URL?
    var sourceURLs: [URL] = []
    var forceOverwrite = false

    init(projectURL: URL? = nil) {
        self.outputURL = Self.defaultOutputURL(projectURL: projectURL)
    }

    var canCreate: Bool {
        deduplicatedFASTA != nil
            && midoriMetadataTSV != nil
            && outputURL != nil
    }

    var buildConfiguration: TwelveSReferenceBundleBuildConfiguration? {
        guard let deduplicatedFASTA,
              let midoriMetadataTSV,
              let outputURL else {
            return nil
        }
        let standardizedSources = sourceURLs.map(\.standardizedFileURL)
        let fileManager = FileManager.default
        let sourceFiles = standardizedSources.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let sourceDirectories = standardizedSources.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: deduplicatedFASTA,
            midoriMetadataTSV: midoriMetadataTSV,
            outputURL: Self.normalizedOutputURL(outputURL),
            name: trimmedName.isEmpty ? nil : trimmedName,
            sourceFiles: sourceFiles,
            sourceDirectories: sourceDirectories,
            forceOverwrite: forceOverwrite
        )
    }

    static func defaultOutputURL(projectURL: URL?) -> URL? {
        guard let projectURL else { return nil }
        return projectURL
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("12S reference.\(TwelveSReferenceBundle.directoryExtension)", isDirectory: true)
            .standardizedFileURL
    }

    static func normalizedOutputURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.pathExtension.lowercased() == TwelveSReferenceBundle.directoryExtension {
            return standardized
        }
        return standardized
            .deletingPathExtension()
            .appendingPathExtension(TwelveSReferenceBundle.directoryExtension)
            .standardizedFileURL
    }
}

private struct TwelveSReferenceBundleBuilderSheet: View {
    let projectURL: URL?
    @Binding var draft: TwelveSReferenceBundleDraft
    let onCancel: () -> Void
    let onCreate: (TwelveSReferenceBundleBuildConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create 12S Reference")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                labeledTextField("Name", text: $draft.name)
                pathRow(
                    title: "Deduplicated FASTA",
                    url: draft.deduplicatedFASTA,
                    placeholder: "No FASTA selected",
                    actionTitle: "Choose\u{2026}",
                    action: chooseDeduplicatedFASTA
                )
                pathRow(
                    title: "Target Metadata",
                    url: draft.midoriMetadataTSV,
                    placeholder: "No metadata TSV selected",
                    actionTitle: "Choose\u{2026}",
                    action: chooseMIDORIMetadata
                )
                pathRow(
                    title: "Output Bundle",
                    url: draft.outputURL.map(TwelveSReferenceBundleDraft.normalizedOutputURL(_:)),
                    placeholder: "No output selected",
                    actionTitle: "Choose\u{2026}",
                    action: chooseOutputBundle
                )
                sourceFilesRow
                Toggle("Replace Existing Bundle", isOn: $draft.forceOverwrite)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let configuration = draft.buildConfiguration {
                        onCreate(configuration)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canCreate)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var sourceFilesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source Files")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(sourceDisplay)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button("Add\u{2026}", action: chooseSourceFiles)
                if !draft.sourceURLs.isEmpty {
                    Button("Clear") {
                        draft.sourceURLs.removeAll()
                    }
                }
            }
        }
    }

    private var sourceDisplay: String {
        switch draft.sourceURLs.count {
        case 0:
            return "No additional sources selected"
        case 1:
            return WorkflowOperationDialogState.displayPath(for: draft.sourceURLs[0], relativeTo: projectURL)
        default:
            return "\(draft.sourceURLs.count) sources selected"
        }
    }

    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func pathRow(
        title: String,
        url: URL?,
        placeholder: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(url.map { WorkflowOperationDialogState.displayPath(for: $0, relativeTo: projectURL) } ?? placeholder)
                    .font(.caption)
                    .foregroundStyle(url == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button(actionTitle, action: action)
            }
        }
    }

    private func chooseDeduplicatedFASTA() {
        let panel = NSOpenPanel()
        panel.title = "Choose Deduplicated 12S FASTA"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = fastaContentTypes()
        runOpenPanel(panel) { url in
            draft.deduplicatedFASTA = url.standardizedFileURL
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.name = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func chooseMIDORIMetadata() {
        let panel = NSOpenPanel()
        panel.title = "Choose 12S Target Metadata"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.plainText]
        if let tsv = UTType(filenameExtension: "tsv") {
            contentTypes.append(tsv)
        }
        if let csv = UTType(filenameExtension: "csv") {
            contentTypes.append(csv)
        }
        panel.allowedContentTypes = contentTypes
        runOpenPanel(panel) { url in
            draft.midoriMetadataTSV = url.standardizedFileURL
        }
    }

    private func chooseOutputBundle() {
        let panel = NSSavePanel()
        panel.title = "Create 12S Reference Bundle"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = draft.outputURL?.lastPathComponent ?? "12S reference.\(TwelveSReferenceBundle.directoryExtension)"
        panel.directoryURL = draft.outputURL?.deletingLastPathComponent()
            ?? projectURL?.appendingPathComponent("Reference Sequences", isDirectory: true)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            draft.outputURL = TwelveSReferenceBundleDraft.normalizedOutputURL(url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func chooseSourceFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference Source Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        runOpenPanel(panel) { _ in
            let selected = panel.urls.map(\.standardizedFileURL)
            draft.sourceURLs = Array(Set(draft.sourceURLs + selected)).sorted { $0.path < $1.path }
        }
    }

    private func runOpenPanel(_ panel: NSOpenPanel, handler: @escaping (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            handler(url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func fastaContentTypes() -> [UTType] {
        var contentTypes: [UTType] = [.plainText]
        for ext in ["fa", "fasta", "fna"] {
            if let type = UTType(filenameExtension: ext) {
                contentTypes.append(type)
            }
        }
        return contentTypes
    }
}
