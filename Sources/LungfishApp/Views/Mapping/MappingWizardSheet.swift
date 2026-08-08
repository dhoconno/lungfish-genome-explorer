// MappingWizardSheet.swift - Shared SwiftUI wizard for read mapping tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct MappingReadGroupFields: Equatable, Sendable {
    var id: String
    var sampleName: String
    var library: String
    var platform: String
    var platformUnit: String

    init(
        id: String,
        sampleName: String,
        library: String,
        platform: String,
        platformUnit: String
    ) {
        self.id = id
        self.sampleName = sampleName
        self.library = library
        self.platform = platform
        self.platformUnit = platformUnit
    }

    static func defaults(sampleName: String, modeID: String) -> MappingReadGroupFields {
        let readGroup = MappingReadGroup.resolved(
            sampleName: sampleName,
            defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: modeID)
        )
        return MappingReadGroupFields(readGroup: readGroup)
    }

    func resolvedReadGroup(sampleName: String, modeID: String) -> MappingReadGroup {
        MappingReadGroup.resolved(
            sampleName: sampleName,
            id: id,
            readGroupSampleName: self.sampleName,
            library: library,
            platform: platform,
            platformUnit: platformUnit,
            defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: modeID)
        )
    }

    private init(readGroup: MappingReadGroup) {
        self.id = readGroup.id
        self.sampleName = readGroup.sampleName
        self.library = readGroup.library
        self.platform = readGroup.platform
        self.platformUnit = readGroup.platformUnit
    }
}

/// The outcome of planning a mapping run across one or more selected
/// bundles: either N per-bundle requests (each with its own correct @RG
/// SM/ID/LB/PU) or a single pooled request, plus an optional warning to
/// surface in the operation history when bundles were pooled.
struct MappingRunPlan: Equatable, Sendable {
    let requests: [MappingRunRequest]
    let mode: MultiBundleRunMode
    let warning: String?
}

struct MappingWizardSheet: View {
    let inputFiles: [URL]
    let projectURL: URL?
    let initialTool: MappingTool
    let embeddedInOperationsDialog: Bool
    let embeddedRunTrigger: Int

    @State private var referenceCandidates: [ReferenceCandidate] = []
    @State private var isLoadingReferences = false
    @State private var selectedReferenceID: String = ""
    @State private var browsedReferenceURL: URL?

    @State private var selectedModeID: String
    @State private var modeWasChangedByUser = false
    @State private var threads: Int
    @State private var includeSecondary = false
    @State private var includeSupplementary = true
    @State private var minMappingQuality = 0
    @State private var showReadGroup = false
    @State private var readGroupIDText: String
    @State private var readGroupSampleText: String
    @State private var readGroupLibraryText: String
    @State private var readGroupPlatformText: String
    @State private var readGroupPlatformUnitText: String
    @State private var showAdvanced = false
    @State private var advancedOptionsText = ""

    @State private var detectedSequenceFormat: SequenceFormat?
    @State private var detectedReadClass: MappingReadClass?
    @State private var observedMaxReadLength: Int?
    @State private var mixedReadClasses = false
    @State private var hasUnclassifiedFASTQInputs = false
    @State private var mixedSequenceFormats = false
    @State private var isInspectingInputs = false
    @State private var multiBundleRunMode: MultiBundleRunMode = .perBundle

    var onRun: ((MappingRunPlan) -> Void)?
    var onCancel: (() -> Void)?
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    init(
        inputFiles: [URL],
        projectURL: URL?,
        initialTool: MappingTool,
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((MappingRunPlan) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.projectURL = projectURL
        self.initialTool = initialTool
        self.embeddedInOperationsDialog = embeddedInOperationsDialog
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange
        let initialModeID = MappingMode.availableModes(for: initialTool).first?.id ?? MappingMode.defaultShortRead.id
        let sampleName = inputFiles.first?.lungfishDisplayName ?? "sample"
        let readGroup = Self.defaultReadGroup(sampleName: sampleName, modeID: initialModeID)
        _selectedModeID = State(initialValue: initialModeID)
        _threads = State(initialValue: ProcessInfo.processInfo.processorCount)
        _readGroupIDText = State(initialValue: readGroup.id)
        _readGroupSampleText = State(initialValue: readGroup.sampleName)
        _readGroupLibraryText = State(initialValue: readGroup.library)
        _readGroupPlatformText = State(initialValue: readGroup.platform)
        _readGroupPlatformUnitText = State(initialValue: readGroup.platformUnit)
    }

    private var inputDisplayName: String {
        inputFiles.first?.lungfishDisplayName ?? ""
    }

    /// `inputFiles` grouped into per-sample bundles (R1/R2 pairs collapsed
    /// to one bundle, unpaired files each their own bundle). Drives the
    /// multi-bundle run-mode picker and the per-bundle request split.
    private var bundles: [[URL]] {
        Self.groupBundles(inputFiles: inputFiles)
    }

    private static let multiBundleRunPolicy = MultiBundleRunPolicy(
        allowedModes: [.perBundle, .combined],
        defaultMode: .perBundle
    )

    private var selectedReferenceCandidate: ReferenceCandidate? {
        referenceCandidates.first(where: { $0.id == selectedReferenceID })
    }

    private var resolvedReferenceURL: URL? {
        if selectedReferenceID == "__browsed__", let browsedReferenceURL {
            return browsedReferenceURL
        }
        return selectedReferenceCandidate?.fastaURL
    }

    private var sourceReferenceBundleURL: URL? {
        if selectedReferenceID == "__browsed__" {
            let sourceURL = ReferenceBundleSourceResolver.canonicalSourceBundleURL(
                for: browsedReferenceURL,
                projectURL: projectURL
            )
            return sourceURL?.pathExtension.lowercased() == "lungfishref" ? sourceURL : nil
        }
        return ReferenceBundleSourceResolver.canonicalSourceBundleURL(
            for: selectedReferenceCandidate?.sourceBundleURL,
            projectURL: projectURL
        )
    }

    private var selectedReferencePathDisplay: String? {
        if selectedReferenceID == "__browsed__", let browsedReferenceURL {
            return displayPath(for: browsedReferenceURL)
        }
        return selectedReferenceCandidate?.displayPath(relativeTo: projectURL)
    }

    private var selectedMode: MappingMode? {
        MappingMode(rawValue: selectedModeID)
    }

    static let readGroupSectionTitle = "Read Group"
    static let advancedSectionTitle = "Advanced Settings"
    static let extraArgumentsFieldTitle = "Extra arguments"

    static func advancedOptionsPlaceholder(for tool: MappingTool) -> String {
        switch tool {
        case .minimap2:
            return "--eqx -N 5"
        case .bwaMem2:
            return "-M -Y"
        case .bowtie2:
            return "--very-sensitive -N 1"
        case .bbmap:
            return "minid=0.97 local=t"
        }
    }

    static func defaultReadGroup(sampleName: String, modeID: String) -> MappingReadGroup {
        MappingReadGroupFields.defaults(sampleName: sampleName, modeID: modeID)
            .resolvedReadGroup(sampleName: sampleName, modeID: modeID)
    }

    static func makeReadGroup(
        sampleName: String,
        modeID: String,
        idText: String,
        sampleText: String,
        libraryText: String,
        platformText: String,
        platformUnitText: String
    ) -> MappingReadGroup {
        MappingReadGroupFields(
            id: idText,
            sampleName: sampleText,
            library: libraryText,
            platform: platformText,
            platformUnit: platformUnitText
        )
        .resolvedReadGroup(sampleName: sampleName, modeID: modeID)
    }

    /// Groups a flat selection of FASTQ input files into per-sample bundles:
    /// R1/R2 pairs (matched by common Illumina/generic naming conventions)
    /// collapse into one two-element bundle; anything left unpaired is its
    /// own single-element bundle. Order of first appearance is preserved.
    static func groupBundles(inputFiles: [URL]) -> [[URL]] {
        let pairSuffixes: [(String, String)] = [
            ("_R1", "_R2"),
            ("_1.", "_2."),
            ("_r1", "_r2"),
            ("_forward", "_reverse"),
        ]

        var matched = Set<URL>()
        var bundles: [[URL]] = []

        for url in inputFiles {
            guard !matched.contains(url) else { continue }
            let name = url.lastPathComponent

            var pairedWith: URL?
            for (p1, p2) in pairSuffixes {
                if name.contains(p1) {
                    let pairName = name.replacingOccurrences(of: p1, with: p2)
                    if let pair = inputFiles.first(where: { $0.lastPathComponent == pairName && $0 != url }) {
                        pairedWith = pair
                        break
                    }
                } else if name.contains(p2) {
                    let pairName = name.replacingOccurrences(of: p2, with: p1)
                    if let pair = inputFiles.first(where: { $0.lastPathComponent == pairName && $0 != url }) {
                        pairedWith = pair
                        break
                    }
                }
            }

            if let pairedWith {
                matched.insert(url)
                matched.insert(pairedWith)
                // Preserve forward/reverse ordering regardless of selection order.
                let isForward = pairSuffixes.contains { name.contains($0.0) }
                bundles.append(isForward ? [url, pairedWith] : [pairedWith, url])
            } else {
                matched.insert(url)
                bundles.append([url])
            }
        }

        return bundles
    }

    /// Builds the request(s) for a mapping run given the selected bundles
    /// and run mode. `.perBundle` yields one `MappingRunRequest` per bundle,
    /// each with its own @RG SM/ID/LB/PU derived from that bundle's sample
    /// name. `.combined` yields a single pooled request with an explicit
    /// "pooled-<n>-bundles" sample name and a non-nil warning describing the
    /// pooling for the operation history. A single bundle never produces a
    /// warning regardless of the selected mode.
    static func buildRunPlan(
        bundles: [[URL]],
        mode: MultiBundleRunMode,
        tool: MappingTool,
        modeID: String,
        referenceFASTAURL: URL,
        sourceReferenceBundleURL: URL?,
        projectURL: URL?,
        outputDirectory: URL,
        readGroupIDText: String,
        readGroupSampleText: String,
        readGroupLibraryText: String,
        readGroupPlatformText: String,
        readGroupPlatformUnitText: String,
        threads: Int,
        includeSecondary: Bool,
        includeSupplementary: Bool,
        minimumMappingQuality: Int,
        advancedArguments: [String]
    ) -> MappingRunPlan {
        func request(
            inputFASTQURLs: [URL],
            sampleName: String,
            readGroup: MappingReadGroup,
            outputDirectory: URL
        ) -> MappingRunRequest {
            MappingRunRequest(
                tool: tool,
                modeID: modeID,
                inputFASTQURLs: inputFASTQURLs,
                referenceFASTAURL: referenceFASTAURL,
                sourceReferenceBundleURL: sourceReferenceBundleURL,
                projectURL: projectURL,
                outputDirectory: outputDirectory,
                sampleName: sampleName,
                readGroup: readGroup,
                pairedEnd: inputFASTQURLs.count == 2,
                threads: threads,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                minimumMappingQuality: minimumMappingQuality,
                advancedArguments: advancedArguments
            )
        }

        // Single bundle (or nothing selected): one request, no pooling, no warning.
        guard bundles.count > 1, mode == .combined else {
            var requests: [MappingRunRequest] = []
            for bundle in bundles {
                let sampleName = bundle.first?.lungfishDisplayName ?? "sample"
                let readGroup = makeReadGroup(
                    sampleName: sampleName,
                    modeID: modeID,
                    idText: bundles.count > 1 ? "" : readGroupIDText,
                    sampleText: bundles.count > 1 ? "" : readGroupSampleText,
                    libraryText: bundles.count > 1 ? "" : readGroupLibraryText,
                    platformText: readGroupPlatformText,
                    platformUnitText: bundles.count > 1 ? "" : readGroupPlatformUnitText
                )
                let bundleOutputDirectory = bundles.count > 1
                    ? outputDirectory.appendingPathComponent(sampleName, isDirectory: true)
                    : outputDirectory
                requests.append(request(
                    inputFASTQURLs: bundle,
                    sampleName: sampleName,
                    readGroup: readGroup,
                    outputDirectory: bundleOutputDirectory
                ))
            }
            return MappingRunPlan(requests: requests, mode: .perBundle, warning: nil)
        }

        // Combined: pool every bundle's files into one request with explicit pooled naming.
        let pooledInputs = bundles.flatMap { $0 }
        let pooledSampleName = "pooled-\(bundles.count)-bundles"
        let readGroup = makeReadGroup(
            sampleName: pooledSampleName,
            modeID: modeID,
            idText: readGroupIDText,
            sampleText: readGroupSampleText,
            libraryText: readGroupLibraryText,
            platformText: readGroupPlatformText,
            platformUnitText: readGroupPlatformUnitText
        )
        let pooledRequest = request(
            inputFASTQURLs: pooledInputs,
            sampleName: pooledSampleName,
            readGroup: readGroup,
            outputDirectory: outputDirectory
        )
        let warning = "Combined \(bundles.count) bundles into one pooled mapping run (\(pooledSampleName)). "
            + "All reads share a single @RG SM tag; per-sample attribution is lost in this BAM."
        return MappingRunPlan(requests: [pooledRequest], mode: .combined, warning: warning)
    }

    private var selectedModeBinding: Binding<String> {
        Binding(
            get: { selectedModeID },
            set: { newValue in
                selectedModeID = newValue
                modeWasChangedByUser = true
            }
        )
    }

    private var compatibilityEvaluation: MappingCompatibilityEvaluation? {
        guard let detectedSequenceFormat, let selectedMode else { return nil }
        return MappingCompatibility.evaluate(
            tool: initialTool,
            mode: selectedMode,
            inputFormat: detectedSequenceFormat,
            readClass: detectedReadClass,
            observedMaxReadLength: observedMaxReadLength
        )
    }

    private var compatibilityPresentation: MappingCompatibilityPresentation {
        MappingCompatibilityPresentation.make(
            compatibility: compatibilityEvaluation,
            hasReference: resolvedReferenceURL != nil,
            hasInputs: !inputFiles.isEmpty,
            detectedSequenceFormat: detectedSequenceFormat,
            detectedReadClass: detectedReadClass,
            mixedReadClasses: mixedReadClasses,
            mixedSequenceFormats: mixedSequenceFormats,
            mixesDetectedAndUnclassifiedReadClasses: detectedReadClass != nil && hasUnclassifiedFASTQInputs
        )
    }

    private var canRun: Bool {
        compatibilityPresentation.isReady && advancedOptionsParseError == nil
    }

    private var modeOptions: [MappingMode] {
        MappingMode.availableModes(for: initialTool)
    }

    var body: some View {
        Group {
            if embeddedInOperationsDialog {
                embeddedBody
            } else {
                standaloneBody
            }
        }
        .frame(width: embeddedInOperationsDialog ? nil : 560, height: embeddedInOperationsDialog ? nil : 560)
        .task {
            await loadReferences()
            await inspectInputs()
            onRunnerAvailabilityChange?(canRun)
        }
        .onAppear {
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: canRun) { _, ready in
            onRunnerAvailabilityChange?(ready)
        }
        .onChange(of: detectedSequenceFormat) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: detectedReadClass) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: mixedReadClasses) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: hasUnclassifiedFASTQInputs) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: mixedSequenceFormats) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: selectedReferenceID) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: selectedModeID) { oldValue, newValue in
            let oldPlatform = MappingReadGroup.defaultPlatform(forModeID: oldValue)
            if readGroupPlatformText == oldPlatform {
                readGroupPlatformText = MappingReadGroup.defaultPlatform(forModeID: newValue)
            }
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInOperationsDialog else { return }
            performRun()
        }
    }

    private var standaloneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView { configurationContent }
            Divider()
            footerSection
        }
    }

    private var embeddedBody: some View {
        ScrollView { configurationContent }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            referenceSection
            Divider()
            modeSection
            if bundles.count > 1 {
                Divider()
                MultiBundleRunModePicker(
                    bundleCount: bundles.count,
                    policy: Self.multiBundleRunPolicy,
                    selection: $multiBundleRunMode
                )
            }
            Divider()
            readGroupSection
            Divider()
            compatibilitySection
            Divider()
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Map Reads (\(initialTool.displayName))")
                    .font(.headline)
                Text("Map reads to a reference genome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(inputDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isLoadingReferences {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for references...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if referenceCandidates.isEmpty && browsedReferenceURL == nil {
                Text("No references found in project.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedReferenceID) {
                    if let browsedReferenceURL {
                        Text(displayPath(for: browsedReferenceURL))
                            .tag("__browsed__")
                    }
                    ForEach(referenceCandidates) { candidate in
                        Text(candidate.pickerDisplayName(relativeTo: projectURL)).tag(candidate.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let selectedReferencePathDisplay {
                    Text(selectedReferencePathDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Button("Browse...") {
                browseForReference()
            }
            .font(.system(size: 12))
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(initialTool == .minimap2 ? "Preset" : "Mode")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if modeOptions.count <= 3 {
                Picker("", selection: selectedModeBinding) {
                    ForEach(modeOptions, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else {
                Picker("", selection: selectedModeBinding) {
                    ForEach(modeOptions, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if let selectedMode {
                Text(modeDescription(for: selectedMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Compatibility")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isInspectingInputs {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Inspecting sequence inputs...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if let detectedSequenceFormat {
                    Text("Detected format: \(detectedSequenceFormat == .fasta ? "FASTA" : "FASTQ")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detectedReadClass {
                    Text("Detected reads: \(detectedReadClass.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let observedMaxReadLength {
                    Text("Observed max read length: \(observedMaxReadLength) bp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(compatibilityPresentation.message)
                    .font(.callout)
                    .foregroundStyle(compatibilityPresentation.color)
            }
        }
    }

    private var readGroupSection: some View {
        DisclosureGroup(Self.readGroupSectionTitle, isExpanded: $showReadGroup) {
            VStack(alignment: .leading, spacing: 10) {
                readGroupField(label: "ID (--rg-id)", text: $readGroupIDText)
                readGroupField(label: "Sample (--rg-sm)", text: $readGroupSampleText)
                readGroupField(label: "Library (--rg-lb)", text: $readGroupLibraryText)
                readGroupField(label: "Platform (--rg-pl)", text: $readGroupPlatformText)
                readGroupField(label: "Platform unit (--rg-pu)", text: $readGroupPlatformUnitText)
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func readGroupField(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .trailing)
            TextField("", text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(Self.advancedSectionTitle, isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Threads:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Stepper("\(threads)", value: $threads, in: 1...ProcessInfo.processInfo.processorCount)
                        .font(.system(size: 12))
                }

                HStack {
                    Text("Secondary alignments:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Toggle("", isOn: $includeSecondary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                HStack {
                    Text("Supplementary:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Toggle("", isOn: $includeSupplementary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                HStack {
                    Text("Min mapping quality:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Stepper("\(minMappingQuality)", value: $minMappingQuality, in: 0...60)
                        .font(.system(size: 12))
                }

                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.extraArgumentsFieldTitle)
                        .font(.system(size: 12))
                    TextField(Self.advancedOptionsPlaceholder(for: initialTool), text: $advancedOptionsText)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    if let advancedOptionsParseError {
                        Text(advancedOptionsParseError)
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var footerSection: some View {
        HStack {
            Text(advancedOptionsParseError ?? compatibilityPresentation.message)
                .font(.caption)
                .foregroundStyle(advancedOptionsParseError == nil ? compatibilityPresentation.color : Color.orange)

            Spacer()

            Button("Cancel") {
                onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            Button("Run") {
                performRun()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func modeDescription(for mode: MappingMode) -> String {
        switch mode {
        case .defaultShortRead:
            return "Best for Illumina short-read DNA mapping."
        case .minimap2Asm5:
            return "Optimized for closely related haplotype or assembly alignment."
        case .minimap2Splice:
            return "Optimized for spliced CDS or cDNA alignment to genomic references."
        case .minimap2MapONT:
            return "Optimized for Oxford Nanopore reads."
        case .minimap2MapHiFi:
            return "Optimized for PacBio HiFi reads."
        case .minimap2MapPB:
            return "Optimized for PacBio CLR reads."
        case .bbmapStandard:
            return "Standard BBMap mode for short or moderate-length reads."
        case .bbmapPacBio:
            return "PacBio-tuned BBMap mode for long PacBio-class reads."
        }
    }

    private func loadReferences() async {
        guard let projectURL else { return }
        isLoadingReferences = true
        let candidates = await Task.detached {
            ReferenceSequenceScanner.scanAll(in: projectURL)
        }.value
        guard !Task.isCancelled else { return }
        referenceCandidates = candidates
        isLoadingReferences = false

        if selectedReferenceID.isEmpty, let first = candidates.first {
            selectedReferenceID = first.id
        }
    }

    private func browseForReference() {
        let panel = MappingWorkflowFilePanelFactory.referenceFASTAPanel(title: "Select Reference FASTA")

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            browsedReferenceURL = url
            selectedReferenceID = "__browsed__"
        }
    }

    private func displayPath(for url: URL) -> String {
        let standardizedTarget = url.standardizedFileURL.path
        guard let projectURL else { return standardizedTarget }

        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard standardizedTarget.hasPrefix(normalizedProjectPath) else {
            return standardizedTarget
        }

        return String(standardizedTarget.dropFirst(normalizedProjectPath.count))
    }

    private func inspectInputs() async {
        isInspectingInputs = true
        let result = await Task.detached(priority: .userInitiated) {
            MappingInputInspection.inspect(urls: inputFiles)
        }.value
        detectedSequenceFormat = result.sequenceFormat
        detectedReadClass = result.readClass
        observedMaxReadLength = result.observedMaxReadLength
        mixedReadClasses = result.mixedReadClasses
        hasUnclassifiedFASTQInputs = result.hasUnclassifiedFASTQInputs
        mixedSequenceFormats = result.mixedSequenceFormats
        autoSelectPreferredModeIfNeeded(
            readClass: result.readClass,
            sequenceFormat: result.sequenceFormat,
            observedMaxReadLength: result.observedMaxReadLength
        )
        isInspectingInputs = false
    }

    private func autoSelectPreferredModeIfNeeded(
        readClass: MappingReadClass?,
        sequenceFormat: SequenceFormat?,
        observedMaxReadLength: Int?
    ) {
        guard !modeWasChangedByUser else { return }
        let inputFormat = sequenceFormat ?? (readClass == nil ? nil : .fastq)
        guard let inputFormat,
              let preferredMode = MappingMode.preferredMode(
                for: initialTool,
                readClass: readClass,
                inputFormat: inputFormat
              ),
              preferredMode.id != selectedModeID else {
            return
        }

        if let selectedMode {
            let evaluation = MappingCompatibility.evaluate(
                tool: initialTool,
                mode: selectedMode,
                inputFormat: inputFormat,
                readClass: readClass,
                observedMaxReadLength: observedMaxReadLength
            )
            guard evaluation.isBlocked else { return }
        }

        selectedModeID = preferredMode.id
    }

    private func performRun() {
        guard canRun, let referenceURL = resolvedReferenceURL, let selectedMode else { return }

        let baseDir = inputFiles.first?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let runToken = String(UUID().uuidString.prefix(8))
        let outputDir = baseDir.appendingPathComponent("mapping-\(runToken)")

        let plan = Self.buildRunPlan(
            bundles: bundles,
            mode: multiBundleRunMode,
            tool: initialTool,
            modeID: selectedMode.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDir,
            readGroupIDText: readGroupIDText,
            readGroupSampleText: readGroupSampleText,
            readGroupLibraryText: readGroupLibraryText,
            readGroupPlatformText: readGroupPlatformText,
            readGroupPlatformUnitText: readGroupPlatformUnitText,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minMappingQuality,
            advancedArguments: advancedArguments()
        )

        onRun?(plan)
    }

    private func advancedArguments() -> [String] {
        (try? AdvancedCommandLineOptions.parse(advancedOptionsText)) ?? []
    }

    private var advancedOptionsParseError: String? {
        do {
            _ = try AdvancedCommandLineOptions.parse(advancedOptionsText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
