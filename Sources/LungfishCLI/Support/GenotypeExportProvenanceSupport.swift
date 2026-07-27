import Foundation
import LungfishWorkflow

enum GenotypeExportProvenanceSupport {
    static func record(
        workflowName: String,
        toolName: String,
        command: [String],
        bundleURL: URL,
        outputURLs: [URL],
        outputDirectory: URL,
        optionPaths: [String: URL],
        explicitOptions: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedOptions: [String: ParameterValue]? = nil,
        additionalInputURLs: [URL] = [],
        additionalInputRecords: [FileRecord] = [],
        excludedInputURLs: [URL] = [],
        startedAt: Date
    ) async throws {
        guard !outputURLs.isEmpty else { return }
        var parameters = optionPaths.mapValues { ParameterValue.file($0) }
        parameters.merge(explicitOptions) { _, explicit in explicit }
        parameters["outputCount"] = .integer(outputURLs.count)
        let consumedInputSnapshotPaths = Set(
            additionalInputRecords.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            }
        )

        let excludedInputPaths = Set(
            excludedInputURLs.map(\.standardizedFileURL.path)
                + additionalInputRecords.map {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                }
        )

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: workflowName,
            parameters: parameters,
            defaults: defaults,
            resolved: resolvedOptions,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputRecords(
                bundleURL: bundleURL,
                excluding: excludedInputPaths
            ) + additionalInputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, role: .input)
            } + additionalInputRecords,
            outputs: outputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, role: .output)
            },
            consumedInputSnapshotPaths: consumedInputSnapshotPaths,
            exitCode: 0,
            wallTime: max(0, Date().timeIntervalSince(startedAt)),
            stderr: nil,
            status: .completed,
            outputDirectory: outputDirectory,
            writeFileSidecars: true
        )
    }

    private static func inputRecords(
        bundleURL: URL,
        excluding excludedPaths: Set<String> = []
    ) -> [FileRecord] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory) else {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "missing",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }
        guard isDirectory.boolValue else {
            return [ProvenanceRecorder.fileRecord(url: bundleURL, role: .input)]
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "unreadable-directory",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }

        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            guard !excludedPaths.contains(url.standardizedFileURL.path) else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true,
                  values.isHidden != true else {
                continue
            }
            records.append(ProvenanceRecorder.fileRecord(url: url, role: .input))
        }
        if records.isEmpty {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "empty-directory",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }
        return records.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}
