// AssemblyContigMaterializationAction.swift — CLI-backed orchestration for assembly contig materialization.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
final class AssemblyContigMaterializationAction {
    enum Error: LocalizedError {
        case projectRootNotFound(URL)
        case bundlePathMissing
        case invalidFASTAOutput

        var errorDescription: String? {
            switch self {
            case .projectRootNotFound(let url):
                return "Could not resolve the enclosing Lungfish project root for assembly result at \(url.path)"
            case .bundlePathMissing:
                return "The CLI completed bundle creation without printing the created bundle path to stdout."
            case .invalidFASTAOutput:
                return "The CLI did not return valid FASTA output for the selected contigs."
            }
        }
    }

    typealias Runner = @Sendable ([String]) async throws -> LungfishCLIRunner.Output

    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var runner: Runner = { arguments in
        try await Task.detached(priority: .userInitiated) {
            try LungfishCLIRunner.run(arguments: arguments)
        }.value
    }

    func copyFASTA(result: AssemblyResult, selectedContigs: [String]) async throws {
        let output = try await runner(cliArguments(result: result, selectedContigs: selectedContigs))
        pasteboard.setString(output.stdout)
    }

    func exportFASTA(result: AssemblyResult, selectedContigs: [String], outputURL: URL) async throws {
        _ = try await runner(cliArguments(result: result, selectedContigs: selectedContigs) + ["--output", outputURL.path])
    }

    func createBundle(
        result: AssemblyResult,
        selectedContigs: [String],
        suggestedName: String
    ) async throws -> URL? {
        guard let projectRoot = ProjectTempDirectory.findProjectRoot(result.outputDirectory)
            ?? ProjectTempDirectory.findProjectRoot(result.contigsPath) else {
            throw Error.projectRootNotFound(result.outputDirectory)
        }
        let output = try await runner(
            cliArguments(result: result, selectedContigs: selectedContigs)
            + ["--bundle", "--bundle-name", suggestedName, "--project-root", projectRoot.path, "--quiet"]
        )
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.bundlePathMissing
        }
        return URL(fileURLWithPath: trimmed)
    }

    func buildBlastRequest(result: AssemblyResult, selectedContigs: [String]) async throws -> BlastRequest {
        let output = try await runner(cliArguments(result: result, selectedContigs: selectedContigs))
        let sequences = try fastaRecords(from: output.stdout)
        let sourceLabel = selectedContigs.count == 1
            ? "contig \(selectedContigs[0])"
            : "\(selectedContigs.count) contigs"
        return BlastRequest(
            taxId: nil,
            sequences: sequences,
            readCount: selectedContigs.count,
            sourceLabel: sourceLabel
        )
    }

    private func cliArguments(result: AssemblyResult, selectedContigs: [String]) -> [String] {
        ["extract", "contigs", "--assembly", result.outputDirectory.path, "--quiet"]
        + selectedContigs.flatMap { ["--contig", $0] }
    }

    private func fastaRecords(from stdout: String) throws -> [String] {
        let lines = stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var records: [String] = []
        var current: [String] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            records.append(current.joined(separator: "\n") + "\n")
            current.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.hasPrefix(">") {
                flushCurrent()
            } else if current.isEmpty, !line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                throw Error.invalidFASTAOutput
            }
            if !line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                current.append(String(line))
            }
        }
        flushCurrent()
        guard !records.isEmpty else {
            throw Error.invalidFASTAOutput
        }
        return records
    }
}
