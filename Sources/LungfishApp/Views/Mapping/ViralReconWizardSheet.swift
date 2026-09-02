import SwiftUI
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
    @State private var selectedPlatformOverride: PlatformOverride = .illumina

    @State private var primerOptions: [PrimerOption] = []
    @State private var selectedPrimerID: String = ""

    @State private var minimumMappedReads: Int = 1000
    @State private var buildError: String?

    /// Controls the sheet can show.
    ///
    /// `reference` and `executor` exist only so tests can assert they are never
    /// returned. Viral Recon is SARS-CoV-2 only and Docker only, so neither is
    /// ever a choice.
    enum VisibleControl: Equatable {
        case inputs
        case platform
        case primerScheme
        case minimumMappedReads
        case readiness
        case reference
        case executor
    }

    static func visibleControls(platformDetected: Bool) -> [VisibleControl] {
        var controls: [VisibleControl] = [.inputs]
        if !platformDetected { controls.append(.platform) }
        controls.append(contentsOf: [.primerScheme, .minimumMappedReads, .readiness])
        return controls
    }

    private var selectedPrimerOption: PrimerOption? {
        primerOptions.first { $0.id == selectedPrimerID }
    }

    private var outputRoot: URL? {
        if let projectURL {
            return projectURL.appendingPathComponent("Analyses", isDirectory: true)
        }
        return inputFiles.first?.deletingLastPathComponent()
    }

    /// The platform detected from the inputs alone, ignoring any override.
    ///
    /// The platform control only appears when this is nil, so an override the
    /// user cannot see must not make it look like detection succeeded.
    private var detectedPlatform: ViralReconPlatform? {
        guard let detected = try? ViralReconWizardInputPolicy.resolveInputs(
            inputFiles,
            platformOverride: nil
        ) else { return nil }
        return try? ViralReconWizardInputPolicy.effectivePlatform(from: detected)
    }

    private var effectivePlatform: ViralReconPlatform? {
        try? ViralReconWizardInputPolicy.effectivePlatform(from: resolvedInputs)
    }

    private var platformDetected: Bool {
        detectedPlatform != nil
    }

    private var readinessEvaluation: ViralReconWizardReadiness.Evaluation {
        ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: !inputFiles.isEmpty,
                effectivePlatform: effectivePlatform,
                inputError: inputError,
                primerManifest: selectedPrimerOption?.bundle.manifest,
                outputRootAvailable: outputRoot != nil,
                minimumMappedReads: minimumMappedReads
            )
        )
    }

    private var canRun: Bool {
        readinessEvaluation.canRun
    }

    private var buildErrorRecoveryKey: BuildErrorRecoveryKey {
        BuildErrorRecoveryKey(
            selectedPrimerID: selectedPrimerID,
            minimumMappedReads: minimumMappedReads
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                ForEach(Self.visibleControls(platformDetected: platformDetected), id: \.self) { control in
                    controlSection(control)
                }
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
        .onChange(of: buildErrorRecoveryKey) { _, _ in
            clearBuildError()
        }
        .onChange(of: selectedPlatformOverride) { _, _ in
            refreshResolvedInputs()
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInOperationsDialog else { return }
            performRun()
        }
    }

    @ViewBuilder
    private func controlSection(_ control: VisibleControl) -> some View {
        switch control {
        case .inputs:
            inputsSection
        case .platform:
            platformSection
        case .primerScheme:
            primerSection
        case .minimumMappedReads:
            minimumMappedReadsSection
        case .readiness:
            readinessSection
        case .reference, .executor:
            EmptyView()
        }
    }

    private var headerSection: some View {
        section("Viral Recon") {
            Text("SARS-CoV-2 consensus and variant analysis from FASTQ bundles. Requires Docker Desktop.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var inputsSection: some View {
        section("Inputs") {
            VStack(alignment: .leading, spacing: 8) {
                Text(inputSummary)
                    .accessibilityIdentifier(ViralReconAccessibilityID.inputSummary)
                    .accessibilityLabel(inputSummary)

                if let inputError {
                    Text(inputError)
                        .font(.callout)
                        .foregroundStyle(Color.lungfishOrangeFallback)
                } else if let effectivePlatform {
                    Text("Platform: \(effectivePlatform.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Shown only when the reads do not name their platform.
    ///
    /// There is no Auto segment here: detection has already been tried and
    /// failed, so offering it again would only reproduce the same failure.
    private var platformSection: some View {
        section("Platform") {
            Picker("Platform", selection: $selectedPlatformOverride) {
                ForEach(PlatformOverride.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(ViralReconAccessibilityID.platformPicker)
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

    private var minimumMappedReadsSection: some View {
        section("Minimum mapped reads") {
            VStack(alignment: .leading, spacing: 4) {
                Stepper(
                    "Minimum mapped reads: \(minimumMappedReads)",
                    value: $minimumMappedReads,
                    in: 1...1_000_000,
                    step: 100
                )
                .accessibilityIdentifier(ViralReconAccessibilityID.minimumMappedReadsStepper)
                Text("A sample with fewer mapped reads than this is dropped from the run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        readinessEvaluation.message
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadInitialData() async {
        await loadPrimerOptions()
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

    private func refreshResolvedInputs() {
        do {
            // Detection wins. The override only reaches the resolver when the
            // reads themselves name no platform, which is the only case where
            // the picker is on screen.
            let platformOverride = platformDetected ? nil : selectedPlatformOverride.platform
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
            onRunnerAvailabilityChange(canRun)
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

        let primer = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: selectedPrimerOption.bundle.url,
            projectURL: projectURL,
            destinationDirectory: stagingDirectory
        )

        return try ViralReconRunRequest(
            samples: samples,
            platform: platform,
            protocol: .amplicon,
            samplesheetURL: samplesheetURL,
            outputDirectory: outputDirectory,
            executor: Self.fixedExecutor,
            version: Self.fixedVersion,
            reference: .genome(ViralReconReferenceCatalog.canonicalAccession),
            primer: primer,
            minimumMappedReads: minimumMappedReads,
            variantCaller: Self.defaultVariantCaller,
            consensusCaller: Self.defaultConsensusCaller,
            skipOptions: Array(ViralReconSkipOption.defaultSelection).sorted { $0.rawValue < $1.rawValue },
            advancedParams: Self.defaultResourceParams(),
            fastqPassDirectoryURL: fastqPassDirectoryURL
        )
    }

    private func clearBuildError() {
        guard buildError != nil else { return }
        buildError = nil
        onRunnerAvailabilityChange(canRun)
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

    static func referenceName(from fastaURL: URL, fallback: String) -> String {
        guard let text = firstFASTAChunk(of: fastaURL),
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

    /// Returns the leading text of a FASTA, decompressing gzip/bgzip input first.
    ///
    /// A compressed reference read with a raw `FileHandle` yields binary bytes,
    /// so the header sniff would silently fall back to the accession field.
    private static func firstFASTAChunk(of fastaURL: URL) -> String? {
        if ViralReconPrimerStager.isCompressedFASTA(fastaURL) {
            return try? ViralReconPrimerStager.readFASTAText(at: fastaURL)
        }
        guard let handle = try? FileHandle(forReadingFrom: fastaURL) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        return String(data: data, encoding: .utf8)
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

    /// Docker is the only executor that reaches a working run, so it is fixed
    /// here rather than offered. The launch path refuses the others outright.
    private static let fixedExecutor: NFCoreExecutor = .docker
    private static let fixedVersion = "3.0.0"
    private static let defaultVariantCaller: ViralReconVariantCaller = .ivar
    private static let defaultConsensusCaller: ViralReconConsensusCaller = .bcftools

    private static func defaultResourceParams() -> [String: String] {
        [
            "max_cpus": String(max(1, min(ProcessInfo.processInfo.processorCount, 8))),
            "max_memory": "8.GB",
        ]
    }
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
        // Version-tolerant: a bundle may name its sequence `NC_045512` while the
        // manifest declares `NC_045512.2`. Matches PrimerSchemeResolver.
        guard known.contains(where: { PrimerSchemeResolver.accessionsMatch($0, requested) }) else {
            throw ValidationError.unknownAccession(requested: requested, known: known)
        }
    }

    private static func knownAccessions(for manifest: PrimerSchemeManifest) -> [String] {
        ([manifest.canonicalAccession] + manifest.equivalentAccessions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum ViralReconWizardPrimerStaging {
    /// Stages a primer scheme against the fixed SARS-CoV-2 reference.
    ///
    /// No bundled scheme ships `primers.fasta`, so the primer sequences have to
    /// be cut out of the reference. When the project already holds
    /// `Downloads/MN908947.3.lungfishref` that happens here. When it does not,
    /// only the BED is staged and the launch path fills in the FASTA once it has
    /// downloaded the reference, which is the one place that download belongs.
    static func stageForCanonicalReference(
        primerBundleURL: URL,
        projectURL: URL?,
        destinationDirectory: URL
    ) throws -> ViralReconPrimerSelection {
        if let referenceFASTAURL = canonicalReferenceFASTAURL(inProject: projectURL) {
            return try ViralReconPrimerStager.stage(
                primerBundleURL: primerBundleURL,
                referenceFASTAURL: referenceFASTAURL,
                referenceName: ViralReconReferenceCatalog.canonicalAccession,
                destinationDirectory: destinationDirectory
            )
        }
        return try ViralReconPrimerStager.stageBEDOnly(
            primerBundleURL: primerBundleURL,
            referenceName: ViralReconReferenceCatalog.canonicalAccession,
            destinationDirectory: destinationDirectory
        )
    }

    /// The FASTA inside the project's canonical reference bundle, if present.
    ///
    /// A downloaded bundle carries a reference manifest, but a bundle assembled
    /// by hand may hold only a FASTA at its root, so both are accepted.
    static func canonicalReferenceFASTAURL(inProject projectURL: URL?) -> URL? {
        guard let projectURL else { return nil }
        let bundleURL = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }

        if let manifestFASTAURL = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            return manifestFASTAURL
        }
        if let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL),
           resolvedURL != bundleURL {
            return resolvedURL
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { SequenceFormat.from(url: $0) == .fasta }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}

enum ViralReconWizardReadiness {
    struct State {
        let hasInputFiles: Bool
        let effectivePlatform: ViralReconPlatform?
        let inputError: String?
        let primerManifest: PrimerSchemeManifest?
        let outputRootAvailable: Bool
        let minimumMappedReads: Int
        let advancedError: String?

        init(
            hasInputFiles: Bool,
            effectivePlatform: ViralReconPlatform?,
            inputError: String?,
            primerManifest: PrimerSchemeManifest?,
            outputRootAvailable: Bool,
            minimumMappedReads: Int,
            advancedError: String? = nil
        ) {
            self.hasInputFiles = hasInputFiles
            self.effectivePlatform = effectivePlatform
            self.inputError = inputError
            self.primerManifest = primerManifest
            self.outputRootAvailable = outputRootAvailable
            self.minimumMappedReads = minimumMappedReads
            self.advancedError = advancedError
        }
    }

    struct Evaluation: Equatable {
        let canRun: Bool
        let message: String
    }

    static func evaluate(_ state: State) -> Evaluation {
        if !state.hasInputFiles {
            return .blocked("Select at least one FASTQ bundle.")
        }
        if let inputError = state.inputError {
            return .blocked(inputError)
        }
        if state.effectivePlatform == nil {
            return .blocked("Select one platform for the selected FASTQ bundles.")
        }
        guard let primerManifest = state.primerManifest else {
            return .blocked("Select a SARS-CoV-2 primer scheme.")
        }
        // The reference is fixed, so the only way it can be wrong now is a
        // primer scheme that was never written against it.
        do {
            try ViralReconWizardPrimerCompatibility.validateGenomeAccession(
                ViralReconReferenceCatalog.canonicalAccession,
                manifest: primerManifest
            )
        } catch {
            return .blocked(error.localizedDescription)
        }
        if !state.outputRootAvailable {
            return .blocked("Choose a project or FASTQ location for outputs.")
        }
        if state.minimumMappedReads <= 0 {
            return .blocked("Minimum mapped reads must be greater than zero.")
        }
        if let advancedError = state.advancedError {
            return .blocked(advancedError)
        }
        return Evaluation(canRun: true, message: "Ready to run Viral Recon.")
    }
}

private extension ViralReconWizardReadiness.Evaluation {
    static func blocked(_ message: String) -> Self {
        Self(canRun: false, message: message)
    }
}

/// The platform choices offered when detection fails.
///
/// There is no Auto case: this control only appears after automatic detection
/// has already failed, so re-offering it would only repeat the failure.
private enum PlatformOverride: String, CaseIterable {
    case illumina
    case nanopore

    var platform: ViralReconPlatform? {
        switch self {
        case .illumina:
            return .illumina
        case .nanopore:
            return .nanopore
        }
    }

    var title: String {
        switch self {
        case .illumina:
            return "Illumina"
        case .nanopore:
            return "Nanopore"
        }
    }
}

private struct BuildErrorRecoveryKey: Equatable {
    let selectedPrimerID: String
    let minimumMappedReads: Int
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

    var errorDescription: String? {
        switch self {
        case .missingPlatform:
            return "select a platform."
        case .missingOutputRoot:
            return "choose a project or output location."
        case .missingPrimer:
            return "select a SARS-CoV-2 primer scheme."
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
