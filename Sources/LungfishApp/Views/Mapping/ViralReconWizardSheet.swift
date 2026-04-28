import SwiftUI
import UniformTypeIdentifiers
import LungfishIO
import LungfishWorkflow

struct ViralReconWizardSheet: View {
    let inputFiles: [URL]
    let projectURL: URL?
    let embeddedInOperationsDialog: Bool
    let embeddedRunTrigger: Int
    let onRun: (ViralReconRunRequest) -> Void
    let onRunnerAvailabilityChange: (Bool) -> Void

    @State private var resolvedInputs: [ViralReconResolvedInput] = []
    @State private var inputError: String?
    @State private var selectedPlatformOverride: PlatformOverride = .auto

    @State private var primerOptions: [PrimerOption] = []
    @State private var selectedPrimerID: String = ""

    @State private var referenceCandidates: [ReferenceCandidate] = []
    @State private var selectedReferenceMode: ReferenceMode = .sarsCoV2Genome
    @State private var genomeAccession: String = "MN908947.3"
    @State private var selectedReferenceID: String = ""
    @State private var browsedReferenceURL: URL?
    @State private var browsedGFFURL: URL?

    @State private var executor: NFCoreExecutor = .docker
    @State private var version: String = "3.0.0"
    @State private var minimumMappedReads: Int = 1000
    @State private var maxCPUs: Int = max(1, min(ProcessInfo.processInfo.processorCount, 8))
    @State private var maxMemory: String = "8.GB"
    @State private var variantCaller: ViralReconVariantCaller = .ivar
    @State private var consensusCaller: ViralReconConsensusCaller = .bcftools
    @State private var skipOptions: Set<ViralReconSkipOption> = [.assembly, .kraken2]
    @State private var buildError: String?

    private var selectedPrimerOption: PrimerOption? {
        primerOptions.first { $0.id == selectedPrimerID }
    }

    private var selectedReferenceCandidate: ReferenceCandidate? {
        referenceCandidates.first { $0.id == selectedReferenceID }
    }

    private var selectedLocalReferenceURL: URL? {
        if selectedReferenceID == Self.browsedReferenceID {
            return browsedReferenceURL
        }
        return selectedReferenceCandidate?.fastaURL
    }

    private var outputRoot: URL? {
        if let projectURL {
            return projectURL.appendingPathComponent("Analyses", isDirectory: true)
        }
        return inputFiles.first?.deletingLastPathComponent()
    }

    private var effectivePlatform: ViralReconPlatform? {
        try? ViralReconWizardInputPolicy.effectivePlatform(from: resolvedInputs)
    }

    private var primerRequiresLocalReference: Bool {
        guard selectedReferenceMode == .sarsCoV2Genome,
              let selectedPrimerOption else { return false }
        return selectedPrimerOption.bundle.fastaURL == nil
    }

    private var canRun: Bool {
        !inputFiles.isEmpty
            && effectivePlatform != nil
            && inputError == nil
            && selectedPrimerOption != nil
            && outputRoot != nil
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && minimumMappedReads > 0
            && maxCPUs > 0
            && !maxMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!primerRequiresLocalReference || selectedLocalReferenceURL != nil)
            && (selectedReferenceMode == .sarsCoV2Genome || selectedLocalReferenceURL != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                inputsSection
                referenceSection
                primerSection
                executionSection
                callersSection
                skipSection
                readinessSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .accessibilityIdentifier(ViralReconAccessibilityID.root)
        .task {
            await loadInitialData()
            onRunnerAvailabilityChange(canRun)
        }
        .onAppear {
            onRunnerAvailabilityChange(canRun)
        }
        .onChange(of: canRun) { _, ready in
            onRunnerAvailabilityChange(ready)
        }
        .onChange(of: selectedPlatformOverride) { _, _ in
            refreshResolvedInputs()
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInOperationsDialog else { return }
            performRun()
        }
    }

    private var headerSection: some View {
        section("Viral Recon") {
            Text("SARS-CoV-2 consensus and variant analysis from FASTQ bundles.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var inputsSection: some View {
        section("Inputs") {
            VStack(alignment: .leading, spacing: 8) {
                Text(inputSummary)
                    .accessibilityIdentifier(ViralReconAccessibilityID.inputSummary)
                Picker("Platform", selection: $selectedPlatformOverride) {
                    ForEach(PlatformOverride.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(ViralReconAccessibilityID.platformPicker)

                if let inputError {
                    Text(inputError)
                        .font(.callout)
                        .foregroundStyle(Color.lungfishOrangeFallback)
                } else if let effectivePlatform {
                    Text("Selected platform: \(effectivePlatform.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var referenceSection: some View {
        section("Reference") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Reference", selection: $selectedReferenceMode) {
                    Text("SARS-CoV-2 Genome").tag(ReferenceMode.sarsCoV2Genome)
                    Text("Local FASTA").tag(ReferenceMode.localFASTA)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(ViralReconAccessibilityID.referenceModePicker)

                if selectedReferenceMode == .sarsCoV2Genome {
                    labeledTextField("Genome", text: $genomeAccession)
                        .accessibilityIdentifier(ViralReconAccessibilityID.genomeField)
                    if primerRequiresLocalReference {
                        Text("Select a local SARS-CoV-2 FASTA below to derive primer sequences for this scheme.")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishOrangeFallback)
                    }
                    localReferencePicker
                } else {
                    localReferencePicker
                    if let browsedGFFURL {
                        Text("Annotation: \(displayPath(for: browsedGFFURL))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Choose GFF...") {
                        browseForGFF()
                    }
                }
            }
        }
    }

    private var localReferencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if referenceCandidates.isEmpty && browsedReferenceURL == nil {
                Text("No project references found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Local FASTA", selection: $selectedReferenceID) {
                    if let browsedReferenceURL {
                        Text(displayPath(for: browsedReferenceURL)).tag(Self.browsedReferenceID)
                    }
                    ForEach(referenceCandidates) { candidate in
                        Text(candidate.pickerDisplayName(relativeTo: projectURL)).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(ViralReconAccessibilityID.referencePicker)
            }
            Button("Choose FASTA...") {
                browseForReference()
            }
        }
    }

    private var primerSection: some View {
        section("Primer Scheme") {
            VStack(alignment: .leading, spacing: 8) {
                if primerOptions.isEmpty {
                    Text("No SARS-CoV-2 primer schemes are available.")
                        .foregroundStyle(Color.lungfishOrangeFallback)
                } else {
                    Picker("Scheme", selection: $selectedPrimerID) {
                        ForEach(primerOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(ViralReconAccessibilityID.primerPicker)

                    if let selectedPrimerOption {
                        Text(selectedPrimerOption.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var executionSection: some View {
        section("Execution") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Executor", selection: $executor) {
                    ForEach(Self.executors, id: \.self) { executor in
                        Text(executor.displayName).tag(executor)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(ViralReconAccessibilityID.executorPicker)

                HStack(spacing: 12) {
                    labeledTextField("Version", text: $version)
                        .accessibilityIdentifier(ViralReconAccessibilityID.versionField)
                    Stepper("Minimum mapped reads: \(minimumMappedReads)", value: $minimumMappedReads, in: 1...1_000_000)
                }

                HStack(spacing: 12) {
                    Stepper("CPUs: \(maxCPUs)", value: $maxCPUs, in: 1...max(ProcessInfo.processInfo.processorCount, 1))
                    labeledTextField("Memory", text: $maxMemory)
                }
            }
        }
    }

    private var callersSection: some View {
        section("Callers") {
            HStack(spacing: 14) {
                Picker("Variants", selection: $variantCaller) {
                    ForEach(ViralReconVariantCaller.allCases, id: \.self) { caller in
                        Text(caller.displayName).tag(caller)
                    }
                }
                Picker("Consensus", selection: $consensusCaller) {
                    ForEach(ViralReconConsensusCaller.allCases, id: \.self) { caller in
                        Text(caller.displayName).tag(caller)
                    }
                }
            }
        }
    }

    private var skipSection: some View {
        section("Skip Options") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(ViralReconSkipOption.allCases, id: \.self) { option in
                    Toggle(option.displayName, isOn: binding(for: option))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var readinessSection: some View {
        section("Readiness") {
            Text(buildError ?? readinessText)
                .font(.callout)
                .foregroundStyle(canRun && buildError == nil ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                .accessibilityIdentifier(ViralReconAccessibilityID.readinessLabel)
        }
    }

    private var inputSummary: String {
        switch inputFiles.count {
        case 0:
            return "No FASTQ bundles selected."
        case 1:
            return displayPath(for: inputFiles[0])
        default:
            return "\(inputFiles.count) FASTQ bundles selected."
        }
    }

    private var readinessText: String {
        if inputFiles.isEmpty {
            return "Select at least one FASTQ bundle."
        }
        if let inputError {
            return inputError
        }
        if effectivePlatform == nil {
            return "Select one platform for the selected FASTQ bundles."
        }
        if selectedPrimerOption == nil {
            return "Select a SARS-CoV-2 primer scheme."
        }
        if selectedReferenceMode == .localFASTA, selectedLocalReferenceURL == nil {
            return "Select a local SARS-CoV-2 reference FASTA."
        }
        if primerRequiresLocalReference {
            return "Select a local SARS-CoV-2 reference FASTA to derive primer sequences."
        }
        if outputRoot == nil {
            return "Choose a project or FASTQ location for outputs."
        }
        return "Ready to run Viral Recon."
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding(for option: ViralReconSkipOption) -> Binding<Bool> {
        Binding(
            get: { skipOptions.contains(option) },
            set: { enabled in
                if enabled {
                    skipOptions.insert(option)
                } else {
                    skipOptions.remove(option)
                }
            }
        )
    }

    private func loadInitialData() async {
        await loadPrimerOptions()
        await loadReferences()
        refreshResolvedInputs()
    }

    private func loadPrimerOptions() async {
        let projectURL = projectURL
        let options = await Task.detached {
            var values = BuiltInPrimerSchemeService.listBuiltInSchemes().map {
                PrimerOption(bundle: $0, source: .builtIn)
            }
            if let projectURL {
                values += PrimerSchemesFolder.listBundles(in: projectURL).map {
                    PrimerOption(bundle: $0, source: .project)
                }
            }
            return values.sorted {
                $0.bundle.manifest.displayName.localizedStandardCompare($1.bundle.manifest.displayName) == .orderedAscending
            }
        }.value
        primerOptions = options
        if selectedPrimerID.isEmpty {
            selectedPrimerID = options.first?.id ?? ""
        }
    }

    private func loadReferences() async {
        guard let projectURL else { return }
        let candidates = await Task.detached {
            ReferenceSequenceScanner.scanAll(in: projectURL)
        }.value
        referenceCandidates = candidates
        if selectedReferenceID.isEmpty {
            selectedReferenceID = candidates.first?.id ?? ""
        }
    }

    private func refreshResolvedInputs() {
        do {
            let platformOverride = selectedPlatformOverride.platform
            let resolved = try ViralReconWizardInputPolicy.resolveInputs(
                inputFiles,
                platformOverride: platformOverride
            )
            resolvedInputs = resolved
            inputError = nil
        } catch {
            resolvedInputs = []
            inputError = Self.describeInputError(error)
        }
        buildError = nil
    }

    private func performRun() {
        buildError = nil
        do {
            let request = try buildRequest()
            onRun(request)
        } catch {
            buildError = "Could not prepare Viral Recon: \(error.localizedDescription)"
            onRunnerAvailabilityChange(false)
        }
    }

    private func buildRequest() throws -> ViralReconRunRequest {
        guard let platform = effectivePlatform else {
            throw WizardError.missingPlatform
        }
        guard let outputRoot else {
            throw WizardError.missingOutputRoot
        }
        guard let selectedPrimerOption else {
            throw WizardError.missingPrimer
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let stagingDirectory = outputRoot.appendingPathComponent(".viralrecon-inputs-\(token)", isDirectory: true)
        let outputDirectory = outputRoot.appendingPathComponent("viralrecon-results-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let samples = try ViralReconInputResolver.makeSamples(from: resolvedInputs)
        let samplesheetURL: URL
        var fastqPassDirectoryURL: URL?
        switch platform {
        case .illumina:
            samplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: stagingDirectory)
        case .nanopore:
            let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: stagingDirectory)
            samplesheetURL = staged.samplesheetURL
            fastqPassDirectoryURL = staged.fastqPassDirectory
        }

        let reference = try buildReference()
        let primer = try buildPrimerSelection(
            option: selectedPrimerOption,
            reference: reference,
            stagingDirectory: stagingDirectory
        )

        return try ViralReconRunRequest(
            samples: samples,
            platform: platform,
            protocol: .amplicon,
            samplesheetURL: samplesheetURL,
            outputDirectory: outputDirectory,
            executor: executor,
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: reference,
            primer: primer,
            minimumMappedReads: minimumMappedReads,
            variantCaller: variantCaller,
            consensusCaller: consensusCaller,
            skipOptions: Array(skipOptions).sorted { $0.rawValue < $1.rawValue },
            advancedParams: advancedParams(),
            fastqPassDirectoryURL: fastqPassDirectoryURL
        )
    }

    private func buildReference() throws -> ViralReconReference {
        switch selectedReferenceMode {
        case .sarsCoV2Genome:
            let trimmed = genomeAccession.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw WizardError.missingGenome }
            return .genome(trimmed)
        case .localFASTA:
            guard let selectedLocalReferenceURL else { throw WizardError.missingReference }
            return .local(fastaURL: selectedLocalReferenceURL, gffURL: browsedGFFURL)
        }
    }

    private func buildPrimerSelection(
        option: PrimerOption,
        reference: ViralReconReference,
        stagingDirectory: URL
    ) throws -> ViralReconPrimerSelection {
        if case .genome(let accession) = reference {
            try ViralReconWizardPrimerCompatibility.validateGenomeAccession(
                accession,
                manifest: option.bundle.manifest
            )
        }

        if case .local(let fastaURL, _) = reference {
            return try ViralReconPrimerStager.stage(
                primerBundleURL: option.bundle.url,
                referenceFASTAURL: fastaURL,
                referenceName: Self.referenceName(from: fastaURL, fallback: genomeAccession),
                destinationDirectory: stagingDirectory
            )
        }

        if let fastaURL = option.bundle.fastaURL {
            return ViralReconPrimerSelection(
                bundleURL: option.bundle.url,
                displayName: option.bundle.manifest.displayName,
                bedURL: option.bundle.bedURL,
                fastaURL: fastaURL,
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: false
            )
        }

        guard let selectedLocalReferenceURL else {
            throw WizardError.missingReferenceForPrimerFasta
        }
        return try ViralReconPrimerStager.stage(
            primerBundleURL: option.bundle.url,
            referenceFASTAURL: selectedLocalReferenceURL,
            referenceName: Self.referenceName(from: selectedLocalReferenceURL, fallback: genomeAccession),
            destinationDirectory: stagingDirectory
        )
    }

    private func advancedParams() -> [String: String] {
        var params: [String: String] = ["max_cpus": String(maxCPUs)]
        let memory = maxMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            params["max_memory"] = memory
        }
        return params
    }

    private func browseForReference() {
        let panel = NSOpenPanel()
        panel.title = "Select SARS-CoV-2 Reference FASTA"
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            browsedReferenceURL = url
            selectedReferenceID = Self.browsedReferenceID
            buildError = nil
        }
    }

    private func browseForGFF() {
        let panel = NSOpenPanel()
        panel.title = "Select SARS-CoV-2 GFF Annotation"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            browsedGFFURL = url
            buildError = nil
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

    private static func referenceName(from fastaURL: URL, fallback: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fastaURL) else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8),
              let header = text.split(separator: "\n").first(where: { $0.hasPrefix(">") }) else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return header
            .dropFirst()
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
            ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describeInputError(_ error: Error) -> String {
        if let resolveError = error as? ViralReconInputResolver.ResolveError {
            switch resolveError {
            case .noInputs:
                return "Select at least one FASTQ bundle."
            case .noFASTQ(let url):
                return "\(url.lastPathComponent) does not contain FASTQ reads."
            case .unsupportedPlatform(let url):
                return "Could not detect an Illumina or Oxford Nanopore platform for \(url.lastPathComponent)."
            case .mixedPlatforms:
                return "Selected bundles mix Illumina and Oxford Nanopore reads. Split the run by platform."
            }
        }
        return error.localizedDescription
    }

    private static let browsedReferenceID = "__browsed__"
    private static let executors: [NFCoreExecutor] = [.docker, .conda, .local]
}

enum ViralReconWizardInputPolicy {
    static func effectivePlatform(from resolvedInputs: [ViralReconResolvedInput]) throws -> ViralReconPlatform? {
        guard !resolvedInputs.isEmpty else { return nil }
        let platforms = Set(resolvedInputs.map(\.platform))
        guard platforms.count == 1 else {
            throw ViralReconInputResolver.ResolveError.mixedPlatforms
        }
        return platforms.first
    }

    static func resolveInputs(
        _ urls: [URL],
        platformOverride: ViralReconPlatform?
    ) throws -> [ViralReconResolvedInput] {
        guard platformOverride != nil else {
            return try ViralReconInputResolver.resolveInputs(from: urls)
        }

        let resolved = try urls.map { url in
            try resolveInput(url, platformOverride: platformOverride)
        }
        _ = try effectivePlatform(from: resolved)
        return resolved
    }

    private static func resolveInput(
        _ url: URL,
        platformOverride: ViralReconPlatform?
    ) throws -> ViralReconResolvedInput {
        do {
            let resolved = try ViralReconInputResolver.resolveInputs(from: [url])
            guard let first = resolved.first else {
                throw ViralReconInputResolver.ResolveError.noInputs
            }
            return first
        } catch let error as ViralReconInputResolver.ResolveError {
            guard case .unsupportedPlatform = error,
                  let platformOverride else {
                throw error
            }
            return try forceResolveInput(url, platform: platformOverride)
        }
    }

    private static func forceResolveInput(_ url: URL, platform: ViralReconPlatform) throws -> ViralReconResolvedInput {
        let fastqURLs: [URL]
        if FASTQBundle.isBundleURL(url) {
            guard let urls = FASTQBundle.resolveAllFASTQURLs(for: url), !urls.isEmpty else {
                throw ViralReconInputResolver.ResolveError.noFASTQ(url)
            }
            fastqURLs = urls
        } else if FASTQBundle.isFASTQFileURL(url) {
            fastqURLs = [url]
        } else {
            throw ViralReconInputResolver.ResolveError.noFASTQ(url)
        }

        return ViralReconResolvedInput(
            bundleURL: url,
            sampleName: sampleName(for: url),
            fastqURLs: fastqURLs,
            platform: platform,
            barcode: nil,
            sequencingSummaryURL: sequencingSummaryURL(in: url)
        )
    }

    private static func sampleName(for url: URL) -> String {
        let firstPass = url.deletingPathExtension().lastPathComponent
        let secondPass = firstPass.hasSuffix(".fastq") || firstPass.hasSuffix(".fq")
            ? URL(fileURLWithPath: firstPass).deletingPathExtension().lastPathComponent
            : firstPass
        return secondPass.isEmpty ? "sample" : secondPass
    }

    private static func sequencingSummaryURL(in url: URL) -> URL? {
        guard FASTQBundle.isBundleURL(url) else { return nil }
        for name in ["sequencing_summary.txt", "sequencing_summary.tsv"] {
            let candidate = url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

enum ViralReconWizardPrimerCompatibility {
    enum ValidationError: Error, LocalizedError, Equatable {
        case unknownAccession(requested: String, known: [String])

        var errorDescription: String? {
            switch self {
            case .unknownAccession(let requested, let known):
                return "\(requested) is not compatible with this SARS-CoV-2 primer scheme. Expected \(known.joined(separator: ", "))."
            }
        }
    }

    static func validateGenomeAccession(
        _ accession: String,
        manifest: PrimerSchemeManifest
    ) throws {
        let requested = accession.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = knownAccessions(for: manifest)
        guard known.contains(requested) else {
            throw ValidationError.unknownAccession(requested: requested, known: known)
        }
    }

    private static func knownAccessions(for manifest: PrimerSchemeManifest) -> [String] {
        ([manifest.canonicalAccession] + manifest.equivalentAccessions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum PlatformOverride: String, CaseIterable {
    case auto
    case illumina
    case nanopore

    var platform: ViralReconPlatform? {
        switch self {
        case .auto:
            return nil
        case .illumina:
            return .illumina
        case .nanopore:
            return .nanopore
        }
    }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .illumina:
            return "Illumina"
        case .nanopore:
            return "Nanopore"
        }
    }
}

private enum ReferenceMode {
    case sarsCoV2Genome
    case localFASTA
}

private struct PrimerOption: Identifiable {
    enum Source {
        case builtIn
        case project
    }

    let bundle: PrimerSchemeBundle
    let source: Source

    var id: String {
        bundle.url.absoluteString
    }

    var title: String {
        switch source {
        case .builtIn:
            return "\(bundle.manifest.displayName) (Built-in)"
        case .project:
            return "\(bundle.manifest.displayName) (Project)"
        }
    }

    var detail: String {
        let accession = bundle.manifest.canonicalAccession
        let reference = accession.isEmpty ? "SARS-CoV-2" : accession
        return "\(reference) · \(bundle.manifest.primerCount) primers · \(bundle.manifest.ampliconCount) amplicons"
    }
}

private enum WizardError: Error, LocalizedError {
    case missingPlatform
    case missingOutputRoot
    case missingPrimer
    case missingGenome
    case missingReference
    case missingReferenceForPrimerFasta

    var errorDescription: String? {
        switch self {
        case .missingPlatform:
            return "select a platform."
        case .missingOutputRoot:
            return "choose a project or output location."
        case .missingPrimer:
            return "select a SARS-CoV-2 primer scheme."
        case .missingGenome:
            return "enter a SARS-CoV-2 genome accession."
        case .missingReference:
            return "select a local SARS-CoV-2 reference FASTA."
        case .missingReferenceForPrimerFasta:
            return "select a local SARS-CoV-2 FASTA so primer sequences can be derived."
        }
    }
}

private extension ViralReconPlatform {
    var displayName: String {
        switch self {
        case .illumina:
            return "Illumina"
        case .nanopore:
            return "Oxford Nanopore"
        }
    }
}

private extension NFCoreExecutor {
    var displayName: String {
        switch self {
        case .docker:
            return "Docker"
        case .conda:
            return "Conda"
        case .local:
            return "Local"
        }
    }
}

private extension ViralReconVariantCaller {
    var displayName: String {
        switch self {
        case .ivar:
            return "iVar"
        case .bcftools:
            return "BCFtools"
        }
    }
}

private extension ViralReconConsensusCaller {
    var displayName: String {
        switch self {
        case .ivar:
            return "iVar"
        case .bcftools:
            return "BCFtools"
        }
    }
}

private extension ViralReconSkipOption {
    var displayName: String {
        switch self {
        case .assembly:
            return "Assembly"
        case .variants:
            return "Variants"
        case .consensus:
            return "Consensus"
        case .fastQC:
            return "FastQC"
        case .kraken2:
            return "Kraken2"
        case .fastp:
            return "fastp"
        case .cutadapt:
            return "Cutadapt"
        case .ivarTrim:
            return "iVar trim"
        case .multiQC:
            return "MultiQC"
        }
    }
}
