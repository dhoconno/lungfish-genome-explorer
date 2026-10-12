// SavontImporterStderrCutTests.swift - The Savont recheck of a cut stderr agrees with the cut
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

/// Row 438 of the Phase 2.7 plan, decision P4 of Phase 2.8. The importer accepts a Savont
/// output only when the record's top-level stderr is the cut of its attempts' stderr, which
/// it recomputes over the record as it reads it back. The writer had rewritten the paths of
/// the cut text first, so a cut that ended inside a project path came back as a path that
/// the reader cannot resolve, and the importer refused a record that was right.
@Suite("Savont importer and the stderr cut")
struct SavontImporterStderrCutTests {
    /// A project that holds the run, with folder names no other test uses.
    private struct Layout {
        let outer = UUID().uuidString
        let projectName = "Study-\(UUID().uuidString).lungfish"
        let parent: URL
        let project: URL
        let analysis: URL
        let input: URL
        let output: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent(outer, isDirectory: true)
            project = parent.appendingPathComponent(projectName, isDirectory: true)
            analysis = project.appendingPathComponent("Analyses/savont-1", isDirectory: true)
            input = analysis.appendingPathComponent("reads.fastq")
            output = analysis.appendingPathComponent("reads-savont-clusters.fasta")
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
            try "@read\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        }
    }

    /// Savont as the pipeline sees it, with the managed tool root of this machine so the
    /// runtime paths survive the writer's rewrite and the reader's resolve.
    private struct LongStderrRunner: SavontProcessRunning {
        let stderr: String

        func run(arguments: [String], workingDirectory: URL) async throws -> SavontProcessResult {
            try ">cluster_depth_5\nACGT\n".write(
                to: workingDirectory.appendingPathComponent("final_asvs.fasta"),
                atomically: true,
                encoding: .utf8
            )
            let toolRoot = PortablePath.defaultManagedRoots.toolRoot
            let micromamba = toolRoot.appendingPathComponent("bin/micromamba").path
            return SavontProcessResult(
                exitCode: 0,
                stdout: "ok",
                stderr: stderr,
                argv: [micromamba, "run", "-n", "savont", "savont"] + arguments,
                runtimeIdentity: ProvenanceRuntimeIdentity(
                    appVersion: "test-app",
                    executablePath: micromamba,
                    operatingSystemVersion: "test-os",
                    architecture: "arm64",
                    gitRevision: "fixture",
                    user: "tester",
                    condaEnvironment: SavontClusteringRunRequest.condaEnvironment,
                    condaPrefix: toolRoot.appendingPathComponent("envs/savont").path
                ),
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11)
            )
        }
    }

    /// A first line that lists 30 project paths with commas between them and is longer than
    /// the 2,048-character head window, then progress lines to take the whole stderr past
    /// 10,240 characters, then a last line. `pad` lengthens the first path.
    private static func stderr(projectPath: String, pad: Int) -> String {
        let paths = [projectPath + "/a" + String(repeating: "a", count: pad)]
            + Array(repeating: projectPath + "/a", count: 29)
        let progress = (1...400).map { "[savont] processed read batch \($0) of 400" }
        return ([paths.joined(separator: ",")] + progress + ["[savont] finished clustering"]).joined(separator: "\n") + "\n"
    }

    /// A stderr whose head cut falls inside the project's own folder name, 3 or more
    /// characters after it starts and 3 or more before it ends. The writer rewrites what
    /// comes before that name as a scratch path, and the reader cannot resolve the result.
    private static func stderrWithTheHeadCutInsideAPath(layout: Layout) throws -> String {
        let projectPath = layout.project.path
        let nameStart = projectPath.count - layout.projectName.count
        for pad in 0..<(projectPath.count + 2) {
            let text = stderr(projectPath: projectPath, pad: pad)
            let characters = Array(text)
            guard let comma = characters[..<ProvenanceStderr.headLength].lastIndex(of: ",") else { continue }
            let offset = ProvenanceStderr.headLength - (comma + 1)
            if ((nameStart + 3)...(projectPath.count - 3)).contains(offset) {
                return text
            }
        }
        throw SetupError.noAlignment
    }

    private enum SetupError: Error {
        case noAlignment
    }

    // MARK: Row 438

    @Test("a long first line of project paths leaves the recheck in agreement with the kept stderr")
    func aLongFirstLineOfProjectPathsLeavesTheRecheckInAgreement() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.parent) }
        let stderr = try Self.stderrWithTheHeadCutInsideAPath(layout: layout)
        #expect(stderr.count > ProvenanceStderr.maxLength)

        let request = FASTQOperationLaunchRequest.savont(request: FASTQSavontClusteringRequest(
            inputURLs: [layout.input],
            outputDirectoryURL: layout.analysis,
            singleInputOutputName: nil,
            threads: 4,
            qualityValueCutoff: 91,
            minimumClusterSize: 4,
            minimumReadLength: 3,
            maximumReadLength: 10,
            singleStrand: true
        ))
        _ = try await SavontClusteringPipeline(
            processRunner: LongStderrRunner(stderr: stderr),
            scratchRootURL: layout.analysis.appendingPathComponent("scratch", isDirectory: true)
        ).run(try SavontClusteringRunRequest(
            inputFASTQURL: layout.input,
            outputFASTAURL: layout.output,
            threads: 4,
            qualityValueCutoff: 91,
            minimumClusterSize: 4,
            minimumReadLength: 3,
            maximumReadLength: 10,
            singleStrand: true
        ))

        let sidecar = ProvenanceRecorder.fileSidecarURL(for: layout.output)
        let envelope = try #require(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar))
        let attempt = try #require(envelope.steps.first { $0.toolName == "savont" })
        #expect(attempt.stderr == stderr, "the attempt keeps its stderr whole, with its paths resolved")

        // The head has no line break in its window, so it keeps nothing, and the tail keeps the
        // whole lines that end the stderr.
        let kept = try #require(envelope.stderr)
        #expect(kept == ProvenanceStderr.truncated(stderr))
        #expect(kept.hasPrefix(ProvenanceStderr.truncationMarker))
        #expect(kept.hasSuffix("[savont] finished clustering\n"))
        let raw = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        #expect(!raw.contains(layout.outer), "a folder name stays in the saved record")
        #expect(!raw.contains(layout.projectName), "a folder name stays in the saved record")

        let imported = try await BundleFASTQOperationImporter(destinationDirectory: layout.analysis).importOutputs(
            at: [layout.output],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: layout.analysis
        )
        #expect(imported == [layout.output])
    }
}
