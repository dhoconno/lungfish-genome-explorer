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

    /// Each element of `inputFiles` IS already one bundle: the sidebar
    /// selection -> `resolveFASTQOperationInputURL` pipeline collapses a
    /// selection down to one `.lungfishfastq`/`.lungfishref` bundle URL (or
    /// one loose sequence file) per selected item before the wizard ever
    /// sees it (`AppDelegate+ToolsMenu.resolveFASTQOperationInputURL`). A
    /// bundle's *contents* (e.g. how many physical FASTQ files, whether
    /// they're an R1/R2 pair) are not knowable here -- they only become
    /// knowable after `FASTQSourceResolver.resolve` expands the bundle URL
    /// into its files, which happens later in `AppDelegate.
    /// runSingleManagedMappingAwaitingCompletion`, one bundle at a time. Do NOT re-derive
    /// bundle boundaries by pattern-matching `_R1`/`_R2` etc. against these
    /// URLs' filenames: two distinct bundles can legitimately be named e.g.
    /// `Run1_R1.lungfishfastq` / `Run1_R2.lungfishfastq`, and matching on
    /// that would silently merge two different samples into one "pair".
    private var bundleCount: Int { inputFiles.count }

    private static let multiBundleRunPolicy = MultiBundleRunPolicy(
        allowedModes: [.perBundle, .combined],
        defaultMode: .perBundle
    )

    private var selectedReferenceCandidate: ReferenceCandidate? {
        referenceCandidates.first(where: { $0.id == selectedReferenceID })
    }

    private var referencePickerDisplayNames: [String: String] {
        ReferenceCandidate.pickerDisplayNames(
            for: referenceCandidates,
            relativeTo: projectURL
        )
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

    /// Builds the request(s) for a mapping run given the selected bundle
    /// URLs (one URL per bundle, UNRESOLVED -- see `bundleCount`'s doc
    /// comment) and run mode.
    ///
    /// `.perBundle` yields one `MappingRunRequest` per bundle, each with its
    /// own @RG SM/ID/LB derived from that bundle's own sample name
    /// (sanitized via `MetagenomicsSampleGrouper.sanitizeSampleId` and
    /// de-duplicated across the fan-out so two bundles with the same leaf
    /// name never collide on @RG ID). `.combined` yields a single pooled
    /// request whose `inputFASTQURLs` are still the raw bundle URLs (still
    /// unresolved -- resolution and pooling of the underlying files happens
    /// later, in `AppDelegate.resolveInputFiles`), with an explicit
    /// `"pooled-<n>-bundles-<runToken>"` sample name (unique per run to
    /// avoid collisions across repeated combined runs) and a non-nil warning
    /// describing the pooling for the operation history.
    ///
    /// IMPORTANT: `pairedEnd` is intentionally left `false` on every request
    /// this function returns -- it CANNOT be correctly determined from
    /// unresolved bundle URLs, only from the files a bundle actually
    /// resolves to. `AppDelegate.runSingleManagedMappingAwaitingCompletion`
    /// recomputes it after `resolveInputFiles`, using
    /// `AppDelegate.resolvedPairedEnd(for:)` (backed by
    /// `MetagenomicsSampleGrouper`) on the actually-resolved file list --
    /// see F2 in the C2 fix-round-1 review.
    static func buildRunPlan(
        bundleURLs: [URL],
        mode: MultiBundleRunMode,
        tool: MappingTool,
        modeID: String,
        referenceFASTAURL: URL,
        sourceReferenceBundleURL: URL?,
        projectURL: URL?,
        outputDirectory: URL,
        runToken: String,
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
                // Placeholder; AppDelegate.
                // runSingleManagedMappingAwaitingCompletion recomputes this
                // from the resolved file list before mapping runs.
                pairedEnd: false,
                threads: threads,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                minimumMappingQuality: minimumMappingQuality,
                advancedArguments: advancedArguments
            )
        }

        // Single bundle (or nothing selected): one request, no pooling, no warning.
        guard bundleURLs.count > 1, mode == .combined else {
            var usedReadGroupIDs = Set<String>()
            var requests: [MappingRunRequest] = []
            for bundleURL in bundleURLs {
                let rawSampleName = bundleURL.lungfishDisplayName
                let sampleName = bundleURLs.count > 1
                    ? MetagenomicsSampleGrouper.sanitizeSampleId(rawSampleName)
                    : rawSampleName
                let readGroupID = bundleURLs.count > 1
                    ? Self.uniqueReadGroupID(sampleName, usedIDs: &usedReadGroupIDs)
                    : (readGroupIDText.isEmpty ? sampleName : readGroupIDText)
                let readGroup = makeReadGroup(
                    sampleName: sampleName,
                    modeID: modeID,
                    idText: bundleURLs.count > 1 ? readGroupID : readGroupIDText,
                    sampleText: bundleURLs.count > 1 ? "" : readGroupSampleText,
                    libraryText: bundleURLs.count > 1 ? "" : readGroupLibraryText,
                    platformText: readGroupPlatformText,
                    // Per-bundle fan-out deliberately does not carry a
                    // meaningful platform-unit value (no real flowcell/lane
                    // metadata is available per bundle here); it falls back
                    // to the sample name like the single-bundle default
                    // path already does, rather than inventing one.
                    platformUnitText: bundleURLs.count > 1 ? "" : readGroupPlatformUnitText
                )
                let bundleOutputDirectory = bundleURLs.count > 1
                    ? outputDirectory.appendingPathComponent(sampleName, isDirectory: true)
                    : outputDirectory
                requests.append(request(
                    inputFASTQURLs: [bundleURL],
                    sampleName: sampleName,
                    readGroup: readGroup,
                    outputDirectory: bundleOutputDirectory
                ))
            }
            return MappingRunPlan(requests: requests, mode: .perBundle, warning: nil)
        }

        // Combined: pool every bundle's (still-unresolved) URL into one
        // request with explicit pooled naming. Resolution + concatenation
        // of the underlying files happens later in AppDelegate.
        let pooledSampleName = "pooled-\(bundleURLs.count)-bundles-\(runToken)"
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
            inputFASTQURLs: bundleURLs,
            sampleName: pooledSampleName,
            readGroup: readGroup,
            outputDirectory: outputDirectory
        )
        let warning = "Combined \(bundleURLs.count) bundles into one pooled mapping run (\(pooledSampleName)). "
            + "All reads share a single @RG SM tag; per-sample attribution is lost in this BAM."
        return MappingRunPlan(requests: [pooledRequest], mode: .combined, warning: warning)
    }

    /// De-duplicates @RG IDs across a per-bundle fan-out: two bundles with
    /// the same sanitized leaf name (e.g. two different project folders
    /// both containing a bundle literally named `sample`) would otherwise
    /// produce two `MappingRunRequest`s with identical `readGroup.id`.
    /// Appends `-2`, `-3`, ... to later collisions.
    private static func uniqueReadGroupID(_ candidate: String, usedIDs: inout Set<String>) -> String {
        guard usedIDs.contains(candidate) else {
            usedIDs.insert(candidate)
            return candidate
        }
        var suffix = 2
        var deduped = "\(candidate)-\(suffix)"
        while usedIDs.contains(deduped) {
            suffix += 1
            deduped = "\(candidate)-\(suffix)"
        }
        usedIDs.insert(deduped)
        return deduped
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
            if bundleCount > 1 {
                Divider()
                MultiBundleRunModePicker(
                    bundleCount: bundleCount,
                    policy: Self.multiBundleRunPolicy,
                    selection: $multiBundleRunMode
                )
            }
            Divider()
            if bundleCount > 1 && multiBundleRunMode == .perBundle {
                // .perBundle: typed Read Group values cannot apply
                // meaningfully to N distinct bundles at once -- each
                // bundle needs its own @RG SM/ID derived from its own
                // sample name -- so the editable section is replaced with
                // an explanatory notice instead of silently discarding
                // whatever the user types into a still-editable field (F4).
                perBundleReadGroupNotice
            } else {
                // Single bundle, or N>1 bundles in .combined mode: exactly
                // one MappingRunRequest will be produced, so the typed
                // fields apply to it directly and stay editable.
                readGroupSection
            }
            Divider()
            compatibilitySection
            Divider()
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var perBundleReadGroupNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.readGroupSectionTitle)
                .font(.system(size: 12, weight: .medium))
            Text("Each bundle gets its own read group, derived automatically from its sample name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                        Text(referencePickerDisplayNames[candidate.id] ?? candidate.displayName)
                            .tag(candidate.id)
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
            bundleURLs: inputFiles,
            mode: multiBundleRunMode,
            tool: initialTool,
            modeID: selectedMode.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDir,
            runToken: runToken,
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
