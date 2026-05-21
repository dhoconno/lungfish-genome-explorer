import Foundation
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
    case ontGenotyping(ONTGenotypingRunRequest)
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
    var selectedReadURLs: [URL]
    var outputDirectoryURL: URL?
    var outputName: String
    var threads: Int
    var minSupport: Int
    var extraArgumentsText: String
    var advancedOptionsExpanded: Bool
    var projectReferenceCandidates: [URL]
    var errorMessage: String?
    var showingError: Bool

    init(
        projectURL: URL?,
        selectedReadURLs: [URL] = [],
        enablementStore: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared
    ) {
        self.projectURL = projectURL?.standardizedFileURL
        self.enablementStore = enablementStore
        self.packageStore = packageStore
        self.selectedReadURLs = Self.deduplicated(selectedReadURLs.map(\.standardizedFileURL))
        self.outputName = "ont-genotyping-report"
        self.threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.minSupport = 1
        self.extraArgumentsText = ""
        self.advancedOptionsExpanded = false
        let referenceCandidates = Self.discoverReferenceBundles(in: projectURL)
        self.projectReferenceCandidates = referenceCandidates
        self.selectedReferenceURL = referenceCandidates.first
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
        guard !selectedReadURLs.isEmpty else {
            return "Select one or more FASTQ bundles."
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
            outputName = "ont-genotyping-report"
        }
    }

    func setReference(_ url: URL?) {
        selectedReferenceURL = url?.standardizedFileURL
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

        if projectChanged || selectedReferenceURL == nil {
            selectedReferenceURL = projectReferenceCandidates.first
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
        switch selectedTool.kind {
        case .ontGenotyping:
            let request = try ONTGenotypingRunRequest(
                inputFASTQURLs: selectedReadURLs,
                referenceSourceURL: selectedReferenceURL,
                outputDirectory: outputDirectoryURL,
                outputName: outputName,
                projectURL: projectURL,
                threads: threads,
                minSupport: minSupport,
                extraArguments: AdvancedCommandLineOptions.parse(extraArgumentsText)
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
    private static let ontGenotypingResultsDirectoryName = "ONT genotyping results"

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
}

enum WorkflowOperationError: Error, LocalizedError, Equatable {
    case incompleteConfiguration(String)
    case unsupportedPackage(String)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration(let reason):
            return reason
        case .unsupportedPackage(let name):
            return "\(name) is not a runnable Nextflow or Snakemake lungfishref/lungfishfastq workflow."
        }
    }
}
