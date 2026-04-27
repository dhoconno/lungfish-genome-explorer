import Foundation
import LungfishWorkflow

@MainActor
final class NFCoreWorkflowDialogModel {
    struct WorkflowDetail: Equatable {
        let title: String
        let overview: String
        let whenToUse: String
        let notFor: String
        let requiredInputs: String
        let expectedOutputs: String
        let exampleUseCase: String
        let runButtonTitle: String
        let keyParameters: [NFCoreWorkflowParameter]
    }

    struct InputCandidate: Identifiable, Equatable {
        let id: URL
        let url: URL
        let displayName: String
        let relativePath: String
    }

    enum ValidationError: Error, Equatable {
        case missingProject
        case missingInputs
        case missingWorkflow
    }

    let projectURL: URL?
    let availableWorkflows: [NFCoreSupportedWorkflow]
    private(set) var inputCandidates: [InputCandidate]
    private let allInputCandidates: [InputCandidate]
    private var selectedInputURLs: Set<URL> = []
    private var parameterValues: [String: String] = [:]

    private(set) var selectedWorkflow: NFCoreSupportedWorkflow?
    var executor: NFCoreExecutor = .docker
    var version: String = ""

    init(
        projectURL: URL?,
        workflows: [NFCoreSupportedWorkflow] = NFCoreSupportedWorkflowCatalog.firstWave,
        fileManager: FileManager = .default
    ) {
        self.projectURL = projectURL?.standardizedFileURL
        self.availableWorkflows = workflows
        self.selectedWorkflow = workflows.first
        self.allInputCandidates = Self.discoverInputCandidates(projectURL: projectURL, fileManager: fileManager)
        self.inputCandidates = []
        if let workflow = workflows.first {
            self.version = workflow.pinnedVersion
            self.parameterValues = workflow.defaultParameterValues
            self.inputCandidates = Self.filterInputCandidates(allInputCandidates, for: workflow)
        }
    }

    func selectWorkflow(named name: String) {
        guard let workflow = availableWorkflows.first(where: { $0.name == name || $0.fullName == name }) else { return }
        selectedWorkflow = workflow
        version = workflow.pinnedVersion
        parameterValues = workflow.defaultParameterValues
        inputCandidates = Self.filterInputCandidates(allInputCandidates, for: workflow)
        selectedInputURLs = selectedInputURLs.filter { selectedURL in
            inputCandidates.contains { $0.url.standardizedFileURL == selectedURL.standardizedFileURL }
        }
    }

    var selectedWorkflowDetail: WorkflowDetail {
        guard let selectedWorkflow else {
            return WorkflowDetail(
                title: "No workflow selected",
                overview: "",
                whenToUse: "",
                notFor: "",
                requiredInputs: "",
                expectedOutputs: "",
                exampleUseCase: "",
                runButtonTitle: "Run",
                keyParameters: []
            )
        }
        return WorkflowDetail(
            title: selectedWorkflow.displayName,
            overview: selectedWorkflow.description,
            whenToUse: selectedWorkflow.whenToUse,
            notFor: selectedWorkflow.notFor,
            requiredInputs: selectedWorkflow.requiredInputs,
            expectedOutputs: selectedWorkflow.expectedOutputs,
            exampleUseCase: selectedWorkflow.exampleUseCase,
            runButtonTitle: selectedWorkflow.runButtonTitle,
            keyParameters: selectedWorkflow.keyParameters
        )
    }

    func parameterValue(for name: String) -> String {
        parameterValues[name] ?? ""
    }

    func setParameterValue(_ value: String, for name: String) {
        parameterValues[name] = value
    }

    func isInputSelected(_ url: URL) -> Bool {
        selectedInputURLs.contains(url.standardizedFileURL)
    }

    func setInputSelected(_ url: URL, selected: Bool) {
        let standardizedURL = url.standardizedFileURL
        if selected {
            selectedInputURLs.insert(standardizedURL)
        } else {
            selectedInputURLs.remove(standardizedURL)
        }
    }

    func selectAllInputs() {
        selectedInputURLs = Set(inputCandidates.map { $0.url.standardizedFileURL })
    }

    func clearInputSelection() {
        selectedInputURLs.removeAll()
    }

    func makeRequest() throws -> NFCoreRunRequest {
        guard let projectURL else { throw ValidationError.missingProject }
        guard let selectedWorkflow else { throw ValidationError.missingWorkflow }
        let selectedInputs = inputCandidates
            .map(\.url)
            .filter { selectedInputURLs.contains($0.standardizedFileURL) }
        guard !selectedInputs.isEmpty else { throw ValidationError.missingInputs }

        let outputDirectory = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("nf-core-\(selectedWorkflow.name)-results", isDirectory: true)
        var params = parameterValues.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if selectedInputs.count == 1 {
            params[selectedWorkflow.primaryInputParameter] = selectedInputs[0].path
        }
        return NFCoreRunRequest(
            workflow: selectedWorkflow,
            version: version,
            executor: executor,
            inputURLs: selectedInputs,
            outputDirectory: outputDirectory,
            params: params
        )
    }

    var bundleRootURL: URL? {
        projectURL?.appendingPathComponent("Analyses", isDirectory: true)
    }

    private static func discoverInputCandidates(projectURL: URL?, fileManager: FileManager) -> [InputCandidate] {
        guard let projectURL else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [InputCandidate] = []
        for case let url as URL in enumerator {
            if url.pathExtension == NFCoreRunBundleStore.directoryExtension {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if shouldSkipDirectory(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, isSupportedInput(url) else { continue }
            let relativePath = relativePath(for: url, projectURL: projectURL)
            candidates.append(InputCandidate(
                id: url.standardizedFileURL,
                url: url.standardizedFileURL,
                displayName: url.lastPathComponent,
                relativePath: relativePath
            ))
        }
        return candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".lungfishrun")
            || name == ".build"
            || name == "build"
            || name == "DerivedData"
    }

    private static func isSupportedInput(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [
            ".fastq", ".fq", ".fastq.gz", ".fq.gz",
            ".fasta", ".fa", ".fna", ".fasta.gz", ".fa.gz",
            ".bam", ".cram", ".vcf", ".vcf.gz", ".csv", ".tsv", ".txt",
        ].contains { name.hasSuffix($0) }
    }

    private static func filterInputCandidates(
        _ candidates: [InputCandidate],
        for workflow: NFCoreSupportedWorkflow
    ) -> [InputCandidate] {
        candidates.filter { candidate in
            let name = candidate.url.lastPathComponent.lowercased()
            return workflow.acceptedInputSuffixes.contains { name.hasSuffix($0) }
        }
    }

    private static func relativePath(for url: URL, projectURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(projectPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(projectPath.count + 1))
    }
}
