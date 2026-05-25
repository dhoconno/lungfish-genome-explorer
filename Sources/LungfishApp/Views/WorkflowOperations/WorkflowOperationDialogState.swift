import Foundation
import LungfishIO
import LungfishWorkflow
import Observation

enum WorkflowOperationToolKind: Equatable, Sendable {
    case ontGenotyping
    case workflowPackage(WorkflowPackageValidationResult)
}

struct WorkflowOperationTool: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: WorkflowOperationToolKind
    let availability: DatasetOperationAvailability
}

enum WorkflowOperationLaunchRequest: Equatable {
    case ontGenotyping(ONTBarcodeDemuxGenotypingRunRequest)
    case workflowPackage(LocalWorkflowRunRequest, bundleRoot: URL)
}

@MainActor
@Observable
final class WorkflowOperationDialogState {
    private let enablementStore: WorkflowLibraryEnablementStore
    private let packageStore: WorkflowLibraryImportedPackageStore

    var projectURL: URL?
    var selectedToolID: String
    var selectedReferenceURL: URL?
    var selectedBarcodeDefinitionURL: URL?
    var selectedReadURLs: [URL]
    var outputDirectoryURL: URL?
    var outputName: String
    var threads: Int
    var minSupport: Int
    var selectedGenotypingMode: AmpliconGenotypingMode
    var selectedGenotypingReadType: AmpliconGenotypingReadType
    var selectedHaplotypeAssayID: String?
    var selectedHaplotypeSpeciesCode: String?
    var selectedHaplotypeDefinitionScope: HaplotypeDefinitionScope?
    var selectedHaplotypeDefinitionSetID: String?
    var extraArgumentsText: String
    var advancedOptionsExpanded: Bool
    var projectReferenceCandidates: [URL]
    var projectBarcodeDefinitionCandidates: [URL]
    var errorMessage: String?
    var showingError: Bool

    init(
        projectURL: URL?,
        selectedReadURLs: [URL] = [],
        enablementStore: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared
    ) {
        let standardizedReadURLs = Self.deduplicated(selectedReadURLs.map(\.standardizedFileURL))
        let standardizedProjectURL = projectURL?.standardizedFileURL
        self.projectURL = standardizedProjectURL
        self.enablementStore = enablementStore
        self.packageStore = packageStore
        self.selectedReadURLs = standardizedReadURLs
        self.outputName = Self.defaultONTGenotypingOutputName(for: standardizedReadURLs)
        self.threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.minSupport = 1
        self.selectedGenotypingMode = .auto
        self.selectedGenotypingReadType = .auto
        self.selectedHaplotypeAssayID = Self.defaultHaplotypeAssayID()
        self.selectedHaplotypeSpeciesCode = nil
        self.selectedHaplotypeDefinitionScope = nil
        self.selectedHaplotypeDefinitionSetID = nil
        self.extraArgumentsText = ""
        self.advancedOptionsExpanded = false
        let referenceCandidates = Self.discoverReferenceBundles(in: standardizedProjectURL)
        let barcodeDefinitionCandidates = Self.discoverBarcodeDefinitionFiles(in: standardizedProjectURL)
        self.projectReferenceCandidates = referenceCandidates
        self.projectBarcodeDefinitionCandidates = barcodeDefinitionCandidates
        self.selectedReferenceURL = referenceCandidates.first
        self.selectedBarcodeDefinitionURL = barcodeDefinitionCandidates.first
        self.errorMessage = nil
        self.showingError = false

        let initialTools = Self.makeTools(
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        let initialToolID = initialTools.first(where: { $0.availability == .available })?.id
            ?? initialTools.first?.id
            ?? Self.ontGenotypingID
        self.selectedToolID = initialToolID
        self.outputDirectoryURL = Self.defaultOutputDirectory(
            projectURL: self.projectURL,
            toolKind: initialTools.first { $0.id == initialToolID }?.kind
        )
    }

    var tools: [WorkflowOperationTool] {
        Self.makeTools(enablementStore: enablementStore, packageStore: packageStore)
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        tools.map {
            DatasetOperationToolSidebarItem(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                availability: $0.availability
            )
        }
    }

    var selectedTool: WorkflowOperationTool? {
        tools.first { $0.id == selectedToolID }
    }

    var haplotypeDefinitionRegistry: GenotypeHaplotypeDefinitionRegistry {
        haplotypeDefinitionLibrary.mergedRegistry()
    }

    var haplotypeDefinitionLibrary: HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: projectURL)
    }

    var compatibleHaplotypeDefinitionRecords: [HaplotypeDefinitionRecord] {
        haplotypeDefinitionLibrary.activeRecords(
            assayID: selectedHaplotypeAssayID,
            speciesCode: selectedHaplotypeSpeciesCode,
            scope: selectedHaplotypeDefinitionScope
        )
    }

    var haplotypeSpeciesOptions: [(code: String, label: String)] {
        let records = haplotypeDefinitionLibrary.activeRecords(
            assayID: selectedHaplotypeAssayID,
            scope: selectedHaplotypeDefinitionScope
        )
        var seen = Set<String>()
        return records.compactMap { record in
            let code = record.definitionSet.speciesCode
            guard seen.insert(code).inserted else { return nil }
            return (code: code, label: "\(record.definitionSet.speciesName) (\(code))")
        }
    }

    var haplotypeScopeOptions: [HaplotypeDefinitionScope] {
        let scopes = Set(
            haplotypeDefinitionLibrary.activeRecords(
                assayID: selectedHaplotypeAssayID,
                speciesCode: selectedHaplotypeSpeciesCode
            )
            .map(\.scope)
        )
        return HaplotypeDefinitionScope.allCases.filter { scopes.contains($0) }
    }

    var datasetLabel: String {
        guard !selectedReadURLs.isEmpty else { return "No read bundles selected" }
        if selectedReadURLs.count == 1 {
            return selectedReadURLs[0].lastPathComponent
        }
        return "\(selectedReadURLs.count) read bundles selected"
    }

    var selectedReferenceDisplay: String {
        guard let selectedReferenceURL else { return "No reference selected" }
        return Self.displayPath(for: selectedReferenceURL, relativeTo: projectURL)
    }

    var selectedReadsDisplay: String {
        guard !selectedReadURLs.isEmpty else { return "No read bundles selected" }
        return selectedReadURLs
            .map { Self.displayPath(for: $0, relativeTo: projectURL) }
            .joined(separator: ", ")
    }

    var outputDirectoryDisplay: String {
        guard let outputDirectoryURL else { return "No output directory selected" }
        return Self.displayPath(for: outputDirectoryURL, relativeTo: projectURL)
    }

    var selectedToolSummary: String {
        selectedTool?.subtitle ?? "Select a workflow to configure."
    }

    var readinessText: String {
        if selectedTool == nil {
            return "Enable a workflow in the Workflow Library before running."
        }
        guard selectedTool?.availability == .available else {
            return selectedTool?.availability.badgeText ?? "Workflow unavailable."
        }
        guard selectedReferenceURL != nil else {
            return "Select a reference bundle or FASTA file."
        }
        if selectedTool?.kind == .ontGenotyping,
           selectedGenotypingMode == .ontBarcodeDemux,
           selectedBarcodeDefinitionURL == nil {
            return "Select a project barcode definition or choose a CSV/TSV file."
        }
        guard !selectedReadURLs.isEmpty else {
            return "Select one or more FASTQ bundles."
        }
        if selectedTool?.kind == .ontGenotyping,
           selectedGenotypingMode == .ontBarcodeDemux,
           selectedReadURLs.count != 1 {
            return "Select one ONT barcode FASTQ bundle."
        }
        guard outputDirectoryURL != nil else {
            return "Select an output directory."
        }
        guard !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an output name."
        }
        if case .workflowPackage(let package) = selectedTool?.kind,
           !Self.packageIsRunnable(package) {
            return "This package must declare a Nextflow or Snakemake runner with lungfishref and lungfishfastq inputs."
        }
        if threads < 1 {
            return "Threads must be at least 1."
        }
        if selectedTool?.kind == .ontGenotyping, minSupport < 1 {
            return "Minimum support must be at least 1."
        }
        if selectedTool?.kind == .ontGenotyping,
           selectedGenotypingMode == .illuminaPaired,
           selectedReadURLs.isEmpty {
            return "Select one or more prepared Illumina sample FASTQ bundles."
        }
        if selectedTool?.kind == .ontGenotyping,
           (try? AdvancedCommandLineOptions.parse(extraArgumentsText)) == nil {
            return "Advanced minimap2 arguments could not be parsed."
        }
        return "Ready to run."
    }

    var isRunEnabled: Bool {
        readinessText == "Ready to run."
    }

    func selectTool(_ id: String) {
        guard tools.first(where: { $0.id == id })?.availability == .available else { return }
        let previousToolKind = selectedTool?.kind
        let previousDefaultOutputDirectory = Self.defaultOutputDirectory(
            projectURL: projectURL,
            toolKind: previousToolKind
        )
        selectedToolID = id
        let nextDefaultOutputDirectory = Self.defaultOutputDirectory(
            projectURL: projectURL,
            toolKind: selectedTool?.kind
        )
        if outputDirectoryURL == nil
            || outputDirectoryURL?.standardizedFileURL == previousDefaultOutputDirectory?.standardizedFileURL {
            outputDirectoryURL = nextDefaultOutputDirectory
        }
        if case .workflowPackage = selectedTool?.kind {
            outputName = selectedTool?.title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-") ?? "workflow-output"
        } else {
            outputName = Self.defaultONTGenotypingOutputName(for: selectedReadURLs)
            if selectedHaplotypeAssayID == nil {
                selectedHaplotypeAssayID = Self.defaultHaplotypeAssayID()
            }
        }
    }

    func setHaplotypeAssay(_ assayID: String?) {
        let trimmedAssayID = assayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedHaplotypeAssayID = trimmedAssayID?.isEmpty == true ? nil : trimmedAssayID
        selectedHaplotypeSpeciesCode = nil
        selectedHaplotypeDefinitionScope = nil
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeSpecies(_ speciesCode: String?) {
        let trimmedSpeciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedHaplotypeSpeciesCode = trimmedSpeciesCode?.isEmpty == true ? nil : trimmedSpeciesCode
        if let selectedHaplotypeDefinitionScope,
           !haplotypeScopeOptions.contains(selectedHaplotypeDefinitionScope) {
            self.selectedHaplotypeDefinitionScope = nil
        }
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeDefinitionScope(_ scope: HaplotypeDefinitionScope?) {
        selectedHaplotypeDefinitionScope = scope
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeDefinition(_ definitionSetID: String?) {
        let trimmedDefinitionSetID = definitionSetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = trimmedDefinitionSetID, !id.isEmpty else {
            selectedHaplotypeDefinitionSetID = nil
            return
        }
        if let record = compatibleHaplotypeDefinitionRecords.first(where: { $0.definitionSet.id == id }) {
            selectedHaplotypeAssayID = record.definitionSet.assayID
            selectedHaplotypeSpeciesCode = record.definitionSet.speciesCode
            selectedHaplotypeDefinitionScope = record.scope
            selectedHaplotypeDefinitionSetID = id
            return
        }
        if let record = haplotypeDefinitionLibrary.activeRecords().first(where: { $0.definitionSet.id == id }) {
            selectedHaplotypeAssayID = record.definitionSet.assayID
            selectedHaplotypeSpeciesCode = record.definitionSet.speciesCode
            selectedHaplotypeDefinitionScope = record.scope
            selectedHaplotypeDefinitionSetID = id
        }
    }

    private func refreshHaplotypeSelectionForCurrentProject() {
        let registry = haplotypeDefinitionRegistry
        if let selectedHaplotypeAssayID,
           registry.assay(id: selectedHaplotypeAssayID) == nil {
            self.selectedHaplotypeAssayID = registry.assays.first?.id
            selectedHaplotypeDefinitionSetID = nil
        } else if selectedHaplotypeAssayID == nil {
            selectedHaplotypeAssayID = registry.assays.first?.id
        }
        guard let selectedHaplotypeDefinitionSetID else { return }
        refreshHaplotypeSelectionForCurrentFilters(selectedDefinitionID: selectedHaplotypeDefinitionSetID)
    }

    private func refreshHaplotypeSelectionForCurrentFilters(selectedDefinitionID: String? = nil) {
        let selectedID = selectedDefinitionID ?? selectedHaplotypeDefinitionSetID
        if let selectedID,
           compatibleHaplotypeDefinitionRecords.contains(where: { $0.definitionSet.id == selectedID }) {
            selectedHaplotypeDefinitionSetID = selectedID
            return
        }
        selectedHaplotypeDefinitionSetID = nil
    }

    func setReference(_ url: URL?) {
        selectedReferenceURL = url?.standardizedFileURL
    }

    func setBarcodeDefinition(_ url: URL?) {
        selectedBarcodeDefinitionURL = url?.standardizedFileURL
    }

    func setReads(_ urls: [URL]) {
        selectedReadURLs = Self.deduplicated(urls.map(\.standardizedFileURL))
    }

    func setOutputDirectory(_ url: URL?) {
        outputDirectoryURL = url?.standardizedFileURL
    }

    func configureProject(projectURL: URL?, selectedReadURLs: [URL]) {
        let standardizedProjectURL = projectURL?.standardizedFileURL
        let projectChanged = self.projectURL != standardizedProjectURL

        self.projectURL = standardizedProjectURL
        setReads(selectedReadURLs)
        projectReferenceCandidates = Self.discoverReferenceBundles(in: standardizedProjectURL)
        projectBarcodeDefinitionCandidates = Self.discoverBarcodeDefinitionFiles(in: standardizedProjectURL)
        refreshHaplotypeSelectionForCurrentProject()

        if projectChanged || selectedReferenceURL == nil {
            selectedReferenceURL = projectReferenceCandidates.first
        }
        if projectChanged || selectedBarcodeDefinitionURL == nil {
            selectedBarcodeDefinitionURL = projectBarcodeDefinitionCandidates.first
        }
        if projectChanged || outputDirectoryURL == nil {
            outputDirectoryURL = Self.defaultOutputDirectory(
                projectURL: standardizedProjectURL,
                toolKind: selectedTool?.kind
            )
        }
    }

    func makeLaunchRequest() throws -> WorkflowOperationLaunchRequest {
        guard let selectedTool,
              let selectedReferenceURL,
              let outputDirectoryURL else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        guard isRunEnabled else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        switch selectedTool.kind {
        case .ontGenotyping:
            guard !selectedReadURLs.isEmpty else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            let barcodeDefinitionURL: URL?
            if selectedGenotypingMode != .illuminaPaired
                && (selectedGenotypingMode == .ontBarcodeDemux || selectedBarcodeDefinitionURL != nil) {
                guard let selectedBarcodeDefinitionURL else {
                    throw WorkflowOperationError.incompleteConfiguration(readinessText)
                }
                do {
                    barcodeDefinitionURL = try projectOwnedBarcodeDefinitionURL(for: selectedBarcodeDefinitionURL)
                } catch {
                    throw WorkflowOperationError.barcodeDefinitionImportFailed(error.localizedDescription)
                }
            } else {
                barcodeDefinitionURL = nil
            }
            let request = ONTBarcodeDemuxGenotypingRunRequest(
                inputFASTQURLs: selectedReadURLs,
                referenceSourceURL: selectedReferenceURL,
                barcodeDefinitionsURL: barcodeDefinitionURL,
                outputDirectory: Self.ontGenotypingBundleURL(
                    outputLocationURL: outputDirectoryURL,
                    outputName: outputName
                ),
                outputName: outputName,
                analysisName: outputName,
                projectURL: projectURL,
                threads: threads,
                minSupport: minSupport,
                haplotypeAssayID: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeAssayID,
                haplotypeSpeciesCode: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeSpeciesCode,
                haplotypeDefinitionScope: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeDefinitionScope,
                haplotypeDefinitionSetID: selectedHaplotypeDefinitionSetID,
                extraArguments: try AdvancedCommandLineOptions.parse(extraArgumentsText),
                mode: selectedGenotypingMode,
                readType: selectedGenotypingReadType
            )
            return .ontGenotyping(request)

        case .workflowPackage(let package):
            return .workflowPackage(
                try makeLocalWorkflowRunRequest(package: package),
                bundleRoot: outputDirectoryURL.appendingPathComponent("Workflow Runs", isDirectory: true)
            )
        }
    }

    private func makeLocalWorkflowRunRequest(
        package: WorkflowPackageValidationResult
    ) throws -> LocalWorkflowRunRequest {
        guard Self.packageIsRunnable(package) else {
            throw WorkflowOperationError.unsupportedPackage(package.manifest.name)
        }
        guard let referenceURL = selectedReferenceURL,
              let readURL = selectedReadURLs.first,
              let outputDirectoryURL else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        let entrypointURL = package.packageURL.appendingPathComponent(package.manifest.runner.entrypoint)
        let engine: WorkflowEngineType
        switch package.manifest.runner.kind {
        case .nextflow:
            engine = .nextflow
        case .snakemake:
            engine = .snakemake
        case .command:
            throw WorkflowOperationError.unsupportedPackage(package.manifest.name)
        }

        var params: [String: String] = [:]
        for input in package.manifest.inputs {
            if input.bundleTypes.contains(.lungfishref) {
                params[input.id] = referenceURL.path
                params["reference_bundle"] = referenceURL.path
            }
            if input.bundleTypes.contains(.lungfishfastq) {
                params[input.id] = readURL.path
                params["reads_bundle"] = readURL.path
            }
        }
        params["outdir"] = outputDirectoryURL.path

        return LocalWorkflowRunRequest(
            workflowURL: entrypointURL,
            engine: engine,
            inputURLs: [referenceURL] + selectedReadURLs,
            outputDirectory: outputDirectoryURL,
            expectedOutputURLs: expectedOutputURLs(for: package, outputDirectoryURL: outputDirectoryURL),
            params: params,
            cpus: threads
        )
    }

    private func projectOwnedBarcodeDefinitionURL(for selectedURL: URL) throws -> URL {
        let sourceURL = selectedURL.standardizedFileURL
        guard let projectURL = projectURL?.standardizedFileURL,
              !Self.isURL(sourceURL, inside: projectURL) else {
            return sourceURL
        }

        let importDirectory = projectURL.appendingPathComponent("Barcode Definitions", isDirectory: true)
        let startedAt = Date()
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let destinationURL = try Self.uniqueBarcodeDefinitionImportURL(
            for: sourceURL,
            in: importDirectory
        )

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        try writeBarcodeDefinitionImportProvenance(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            startedAt: startedAt,
            completedAt: Date()
        )

        projectBarcodeDefinitionCandidates = Self.discoverBarcodeDefinitionFiles(in: projectURL)
        selectedBarcodeDefinitionURL = destinationURL
        return destinationURL
    }

    private func writeBarcodeDefinitionImportProvenance(
        sourceURL: URL,
        destinationURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv = [
            "Lungfish.app",
            "workflow-operations",
            "import-barcode-definition",
            "--input",
            sourceURL.path,
            "--output",
            destinationURL.path,
        ]
        let options: [String: ParameterValue] = [
            "source": .file(sourceURL),
            "destination": .file(destinationURL),
            "importDirectory": .file(destinationURL.deletingLastPathComponent()),
        ]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "Workflow Operations Barcode Definition Import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: options, defaults: [:], resolved: options)
        .input(sourceURL, format: Self.barcodeDefinitionFileFormat(for: sourceURL), role: .input)
        .output(destinationURL, format: Self.barcodeDefinitionFileFormat(for: destinationURL), role: .output)
        .runtime(ProvenanceRuntimeIdentity())
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
        try ProvenanceWriter(signingProvider: nil).write(
            envelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: destinationURL)
        )
    }

    private func expectedOutputURLs(
        for package: WorkflowPackageValidationResult,
        outputDirectoryURL: URL
    ) -> [URL] {
        package.manifest.outputs.map { output in
            outputDirectoryURL.appendingPathComponent(
                renderPathTemplate(output.pathTemplate),
                isDirectory: output.bundleType.rawValue.hasPrefix("lungfish")
            )
        }
    }

    private func renderPathTemplate(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{outputName}", with: outputName)
            .replacingOccurrences(of: "{{outputName}}", with: outputName)
    }

    private static let ontGenotypingID = "builtin.ont-genotyping"
    private static let ontGenotypingResultsDirectoryName = "Amplicon genotyping results"

    private static func defaultHaplotypeAssayID() -> String? {
        GenotypeHaplotypeDefinitionRegistry.builtIn.assays.first?.id
    }

    private static func ontGenotypingBundleURL(
        outputLocationURL: URL,
        outputName: String
    ) -> URL {
        let standardized = outputLocationURL.standardizedFileURL
        if ONTGenotypeResultBundle.isBundleURL(standardized) {
            return standardized
        }
        let stem = sanitizeFilenameStem(outputName)
        return standardized.appendingPathComponent(
            "\(stem).\(ONTGenotypeResultBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private static func defaultOutputDirectory(
        projectURL: URL?,
        toolKind: WorkflowOperationToolKind?
    ) -> URL? {
        guard let projectURL else { return nil }
        let analysesDirectory = projectURL.standardizedFileURL
            .appendingPathComponent("Analyses", isDirectory: true)
        switch toolKind {
        case .ontGenotyping:
            return analysesDirectory.appendingPathComponent(
                ontGenotypingResultsDirectoryName,
                isDirectory: true
            )
        case .workflowPackage:
            return analysesDirectory
        case nil:
            return analysesDirectory
        }
    }

    private static func makeTools(
        enablementStore: WorkflowLibraryEnablementStore,
        packageStore: WorkflowLibraryImportedPackageStore
    ) -> [WorkflowOperationTool] {
        var tools: [WorkflowOperationTool] = []
        if let ont = WorkflowLibraryCatalog.item(for: .ontGenotyping) {
            tools.append(WorkflowOperationTool(
                id: ontGenotypingID,
                title: ont.title,
                subtitle: ont.subtitle,
                kind: .ontGenotyping,
                availability: enablementStore.isWorkflowEnabled(.ontGenotyping)
                    ? .available
                    : .disabled(reason: "Enable in Library")
            ))
        }

        tools += packageStore.validatedPackages().map { package in
            let enabled = enablementStore.isUserWorkflowEnabled(package)
            let runnable = packageIsRunnable(package)
            return WorkflowOperationTool(
                id: "package.\(package.manifest.id)",
                title: package.manifest.name,
                subtitle: package.manifest.description ?? "User workflow package",
                kind: .workflowPackage(package),
                availability: enabled && runnable
                    ? .available
                    : .disabled(reason: runnable ? "Enable in Library" : "Unsupported")
            )
        }
        return tools
    }

    private static func packageIsRunnable(_ package: WorkflowPackageValidationResult) -> Bool {
        switch package.manifest.runner.kind {
        case .nextflow, .snakemake:
            break
        case .command:
            return false
        }
        let hasReferenceInput = package.manifest.inputs.contains {
            $0.required && $0.bundleTypes.contains(.lungfishref)
        }
        let hasFASTQInput = package.manifest.inputs.contains {
            $0.required && $0.bundleTypes.contains(.lungfishfastq)
        }
        return hasReferenceInput && hasFASTQInput && !package.manifest.outputs.isEmpty
    }

    private static func discoverReferenceBundles(in projectURL: URL?) -> [URL] {
        guard let projectURL else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var refs: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "lungfishref" else { continue }
            refs.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }
        return refs.sorted {
            displayPath(for: $0, relativeTo: projectURL)
                .localizedStandardCompare(displayPath(for: $1, relativeTo: projectURL)) == .orderedAscending
        }
    }

    private static func discoverBarcodeDefinitionFiles(in projectURL: URL?) -> [URL] {
        guard let projectURL else { return [] }
        let allowedExtensions = Set(["csv", "tsv", "txt"])
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension.lowercased().hasPrefix("lungfish") {
                enumerator.skipDescendants()
                continue
            }
            guard allowedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            candidates.append(url.standardizedFileURL)
        }
        return candidates.sorted {
            displayPath(for: $0, relativeTo: projectURL)
                .localizedStandardCompare(displayPath(for: $1, relativeTo: projectURL)) == .orderedAscending
        }
    }

    private static func uniqueBarcodeDefinitionImportURL(
        for sourceURL: URL,
        in directoryURL: URL
    ) throws -> URL {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedStem = sanitizeFilenameStem(sourceStem)
        let baseName = sourceExtension.isEmpty ? sanitizedStem : "\(sanitizedStem).\(sourceExtension)"
        let firstCandidate = directoryURL.appendingPathComponent(baseName)
        if try candidate(firstCandidate, matchesSource: sourceURL) {
            return firstCandidate.standardizedFileURL
        }

        var suffix = 2
        while true {
            let candidateName = sourceExtension.isEmpty
                ? "\(sanitizedStem)-\(suffix)"
                : "\(sanitizedStem)-\(suffix).\(sourceExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if try candidate(candidateURL, matchesSource: sourceURL) {
                return candidateURL.standardizedFileURL
            }
            suffix += 1
        }
    }

    private static func candidate(_ candidateURL: URL, matchesSource sourceURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return true
        }
        return try ProvenanceFileHasher.sha256(of: candidateURL) == ProvenanceFileHasher.sha256(of: sourceURL)
    }

    private static func barcodeDefinitionFileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv", "txt":
            return .text
        default:
            return .unknown
        }
    }

    private static func isURL(_ url: URL, inside projectURL: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        if targetPath == projectPath { return true }
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        return targetPath.hasPrefix(normalizedProjectPath)
    }

    static func displayPath(for url: URL, relativeTo projectURL: URL?) -> String {
        let targetPath = url.standardizedFileURL.path
        guard let projectURL else { return targetPath }
        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard targetPath.hasPrefix(normalizedProjectPath) else { return targetPath }
        return String(targetPath.dropFirst(normalizedProjectPath.count))
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func defaultONTGenotypingAnalysisName(for selectedReadURLs: [URL]) -> String {
        guard let stem = selectedReadURLs.first?.deletingPathExtension().lastPathComponent.lowercased() else {
            return "ONT"
        }
        if let range = stem.range(of: #"barcode[-_ ]?([0-9]+)"#, options: .regularExpression) {
            let match = String(stem[range])
            let digits = match.filter(\.isNumber)
            if !digits.isEmpty {
                return "ONT\(digits)"
            }
        }
        return "ONT"
    }

    private static func defaultONTGenotypingOutputName(for selectedReadURLs: [URL]) -> String {
        guard let stem = selectedReadURLs.first?.deletingPathExtension().lastPathComponent,
              !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ont-mhc"
        }
        return "\(sanitizeFilenameStem(stem))-mhc"
    }

    private static func sanitizeFilenameStem(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ont" : collapsed
    }
}

enum WorkflowOperationError: Error, LocalizedError, Equatable {
    case incompleteConfiguration(String)
    case unsupportedPackage(String)
    case barcodeDefinitionImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration(let reason):
            return reason
        case .unsupportedPackage(let name):
            return "\(name) is not a runnable Nextflow or Snakemake lungfishref/lungfishfastq workflow."
        case .barcodeDefinitionImportFailed(let reason):
            return "Could not import the barcode definition into the project: \(reason)"
        }
    }
}
