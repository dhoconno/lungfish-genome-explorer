// SpelledDestinationHarness.swift - Drives each primer design engine's own entry with a destination spelled through a link
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.49 (moved-out row M852, PARENT-NOFOLLOW). `/tmp` and `/var` are links into `/private`, so a project
// or `--output` spelled `/tmp/...` or `/var/folders/...` reaches a design pipeline through a link. Each function here
// builds one design request for an engine under such a spelling, runs the engine's own design entry with a stand-in
// runner, and returns what happened, so a test can read which path reached `PrimerAnalysisBundleWriter` and whether the
// design saved. The stand-ins replace only the native tool run. Destination handling, scratch storage and publication
// are the pipelines' own code.

import Darwin
import Foundation
import LungfishIO
import XCTest
import os
@testable import LungfishWorkflow

/// A scratch folder with two spellings. `spelled` goes through `/tmp` or `/var`, `physical` is the same folder with
/// every link resolved (`/private/tmp/...`, `/private/var/folders/...`).
final class SpelledProject: @unchecked Sendable {
    enum Spelling: String, CaseIterable, Sendable {
        case tmp
        case varFolders
    }

    let spelling: Spelling
    let spelled: URL
    let physical: URL

    init(_ spelling: Spelling) throws {
        let base: URL
        switch spelling {
        case .tmp: base = URL(fileURLWithPath: "/tmp", isDirectory: true)
        case .varFolders: base = try Self.varFoldersBase()
        }
        let folder = base.appendingPathComponent("lungfish-13.49-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let resolved = realpath(folder.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        self.spelling = spelling
        self.spelled = folder
        self.physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// `FileManager.default.temporaryDirectory` when it is under `/var/folders`, and the per-user folder otherwise, so
    /// a different `TMPDIR` still tests the `/var/folders` spelling.
    private static func varFoldersBase() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        if temporary.path.hasPrefix("/var/folders/") { return temporary }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw XCTSkip("This host has no per-user /var/folders temporary directory.")
        }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard path.hasPrefix("/var/folders/") else {
            throw XCTSkip("This host's per-user temporary directory is not under /var/folders.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The `Analyses` folder by its physical path, the real folder a project keeps its analyses in.
    var analyses: URL { physical.appendingPathComponent("Analyses", isDirectory: true) }

    /// The destination bundle as a request spells it, through the link.
    var spelledDestination: URL {
        spelled.appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("result.lungfishprimeranalysis", isDirectory: true)
    }

    /// The same bundle by its physical path.
    var physicalDestination: URL {
        analyses.appendingPathComponent("result.lungfishprimeranalysis", isDirectory: true)
    }

    func makeAnalysesFolder() throws {
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: physical) }
}

/// What one engine's design entry did with a destination spelled through a link.
struct SpelledRun {
    let project: SpelledProject
    let result: Result<URL, Error>
    /// A path the stand-in runner was handed. It sits in the run's private storage, which the pipeline places beside the
    /// destination, so it shows how the pipeline spelled the folder that holds the writer's source files.
    let runnerPath: String?
}

/// The project is reached through a link, so a test means what it says.
func assertSpelledThroughALink(_ run: SpelledRun, file: StaticString = #filePath, line: UInt = #line) {
    let project = run.project
    switch project.spelling {
    case .tmp:
        XCTAssertTrue(project.spelled.path.hasPrefix("/tmp/"), project.spelled.path, file: file, line: line)
        XCTAssertTrue(project.physical.path.hasPrefix("/private/tmp/"), project.physical.path, file: file, line: line)
    case .varFolders:
        XCTAssertTrue(project.spelled.path.hasPrefix("/var/folders/"), project.spelled.path, file: file, line: line)
        XCTAssertTrue(
            project.physical.path.hasPrefix("/private/var/folders/"), project.physical.path, file: file, line: line)
    }
}

/// The folder the stand-in runner worked in is spelled through the link (`isSpelled`) or by its physical path.
func assertRunnerPath(
    _ run: SpelledRun, isSpelled: Bool, file: StaticString = #filePath, line: UInt = #line
) {
    let root = (isSpelled ? run.project.spelled : run.project.physical).path + "/"
    XCTAssertTrue(
        run.runnerPath?.hasPrefix(root) == true, "\(run.runnerPath ?? "no runner path") should start with \(root)",
        file: file, line: line)
}

/// The design saved a loadable bundle at the physical destination, or at `destination` when a test names another
/// physical path (a folder the user linked). Returns the bundle so a test can read its record.
@discardableResult
func assertSpelledRunSaved(
    _ run: SpelledRun, at destination: URL? = nil, file: StaticString = #filePath, line: UInt = #line
) -> PrimerAnalysisBundle? {
    switch run.result {
    case .failure(let error):
        XCTFail(
            "The design did not save under a \(run.project.spelling) spelling: \(error) \(error.localizedDescription)",
            file: file, line: line)
        return nil
    case .success(let url):
        XCTAssertEqual(
            url.path, (destination ?? run.project.physicalDestination).path, "the bundle is published at the physical path",
            file: file, line: line)
        do {
            return try PrimerAnalysisBundle.load(from: url)
        } catch {
            XCTFail("The saved bundle did not load: \(error)", file: file, line: line)
            return nil
        }
    }
}

/// The design failed, and the failure text (the error and its description) is returned.
func failureText(_ run: SpelledRun, file: StaticString = #filePath, line: UInt = #line) -> String? {
    guard case .failure(let error) = run.result else {
        XCTFail("The design saved, which this test says it must not.", file: file, line: line)
        return nil
    }
    return "\(error) \(error.localizedDescription)"
}

enum SpelledDestinationHarness {
    // MARK: - Olivar and varVAMP, through PrimerSchemeDesignPipeline

    static func varvamp(_ spelling: SpelledProject.Spelling) async throws -> SpelledRun {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        return try await scheme(spelling, fixture: fixture, options: fixture.tiledOptions, bases: 100) { command in
            try fixture.writeAdapterSuccess(command: command, mode: .tiled)
        }
    }

    /// `prepare` runs once the project and its `Analyses` folder exist and before the design starts, and `afterRunner`
    /// runs inside the stand-in runner right after it wrote its output. Both default to nothing.
    static func olivar(
        _ spelling: SpelledProject.Spelling,
        prepare: @escaping @Sendable (SpelledProject) throws -> Void = { _ in },
        afterRunner: @escaping @Sendable (SpelledProject) throws -> Void = { _ in }
    ) async throws -> SpelledRun {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent, nominalAmpliconLength: 150,
            minimumAmpliconLength: 120, maximumAmpliconLength: 190, workers: 1, olivar: .init())
        return try await scheme(
            spelling, fixture: fixture, options: options, bases: OlivarAdapterStandIn.referenceLength,
            prepare: prepare, afterRunner: afterRunner
        ) { command in try OlivarAdapterStandIn.writeSuccess(command: command, fixture: fixture) }
    }

    private static func scheme(
        _ spelling: SpelledProject.Spelling, fixture: PrimerSchemePipelineFixture, options: PrimerSchemeDesignOptions,
        bases: Int, prepare: @escaping @Sendable (SpelledProject) throws -> Void = { _ in },
        afterRunner: @escaping @Sendable (SpelledProject) throws -> Void = { _ in },
        writeOutput: @escaping @Sendable (PrimerSchemeAdapterCommand) throws -> Void
    ) async throws -> SpelledRun {
        let project = try SpelledProject(spelling)
        try project.makeAnalysesFolder()
        let content = Data((">row-a\n" + String(repeating: "ACGT", count: bases / 4) + "\n").utf8)
        try content.write(to: project.physical.appendingPathComponent("input.fasta"))
        let input = project.spelled.appendingPathComponent("input.fasta")
        do {
            try prepare(project)
        } catch {
            project.remove()
            throw error
        }
        let seen = OSAllocatedUnfairLock<String?>(initialState: nil)
        let pipeline = fixture.pipeline { command in
            seen.withLock { $0 = command.outputDirectoryURL.path }
            // The adapter records `run.py` by `Path.resolve()`, which keeps `/private`, as 12.16 c3 measured.
            let recorded = recording(command, runPy: physicalPath(command.arguments[0]))
            try writeOutput(recorded)
            try afterRunner(project)
            return fixture.execution(for: command)
        }
        let request = PrimerSchemeDesignRequest(
            analysisID: fixture.analysisID, runID: fixture.runID, resultID: fixture.resultID,
            inputURLs: [input], destinationURL: project.spelledDestination, options: options,
            invocation: .init(
                argv: ["lungfish", "primer", "design", options.engine.rawValue, "--output", project.spelledDestination.path],
                callerVersion: "test",
                explicitOptions: options.provenanceOptions, runtimeIdentity: fixture.runtime),
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)],
            executableURL: fixture.executableURL, inputIDs: [input: fixture.inputID])
        do {
            let url = try await pipeline.run(request: request)
            return SpelledRun(project: project, result: .success(url), runnerPath: seen.withLock { $0 })
        } catch {
            return SpelledRun(project: project, result: .failure(error), runnerPath: seen.withLock { $0 })
        }
    }

    // MARK: - Primer3, through Primer3DesignPipeline

    static func primer3(_ spelling: SpelledProject.Spelling) async throws -> SpelledRun {
        let project = try SpelledProject(spelling)
        try project.makeAnalysesFolder()
        let text = ">same\n" + String(repeating: "ACGT", count: 80) + "\n>same\n" + String(repeating: "TGCA", count: 80) + "\n"
        try Data(text.utf8).write(to: project.physical.appendingPathComponent("duplicate.fa"))
        let fasta = project.spelled.appendingPathComponent("duplicate.fa")
        let seen = OSAllocatedUnfairLock<String?>(initialState: nil)
        let runner: Primer3DesignRunner = { invocation in
            seen.withLock { $0 = invocation.outputURL.path }
            let input = try String(contentsOf: invocation.inputURL, encoding: .utf8)
            let lines = input.split(separator: "\n")
            guard let idLine = lines.first(where: { $0.hasPrefix("SEQUENCE_ID=") }),
                let templateLine = lines.first(where: { $0.hasPrefix("SEQUENCE_TEMPLATE=") })
            else { throw CocoaError(.fileReadUnknown) }
            let output = primer3Output(
                resultID: String(idLine.dropFirst("SEQUENCE_ID=".count)),
                template: String(templateLine.dropFirst("SEQUENCE_TEMPLATE=".count)))
            try Data(output.utf8).write(to: invocation.outputURL)
            return Primer3RunReceipt(
                argv: ["/managed/primer3_core", "--output=\(invocation.outputURL.path)", invocation.inputURL.path],
                stdout: "", stderr: "notice", exitStatus: 0, version: "2.6.1",
                runtimeIdentity: .init(executablePath: "/managed/primer3_core", condaEnvironment: "primer3"),
                startedAt: Date(), endedAt: Date())
        }
        let pipeline = Primer3DesignPipeline(
            runner: runner, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
        let request = Primer3DesignRequest(
            inputURLs: [fasta], selections: [.fastaRecord(inputURL: fasta, recordIndex: 1)],
            destinationURL: project.spelledDestination, options: primer3Options,
            invocation: PrimerAnalysisWrapperInvocation(
                argv: ["lungfish", "primer3"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
            expectedInputChecksums: [fasta: try Primer3InputLoader.fingerprint(fasta)])
        do {
            let url = try await pipeline.run(request: request)
            return SpelledRun(project: project, result: .success(url), runnerPath: seen.withLock { $0 })
        } catch {
            return SpelledRun(project: project, result: .failure(error), runnerPath: seen.withLock { $0 })
        }
    }

    private static var primer3Options: Primer3DesignOptions {
        Primer3DesignOptions(
            productSizeMin: 100, productSizeMax: 240, targetStart: 11, targetEnd: 30,
            pairCount: 2, primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
            primerMinTm: 57, primerOptTm: 60, primerMaxTm: 63,
            primerMinGC: 30, primerMaxGC: 70, pickInternalOligo: true)
    }

    private static func primer3Output(resultID: String, template: String) -> String {
        let left = String(template.dropFirst(5).prefix(20))
        let rightTemplate = String(template.dropFirst(79).prefix(21))
        let right = String(rightTemplate.reversed().map { base in
            switch base { case "A": "T"; case "C": "G"; case "G": "C"; case "T": "A"; default: "N" }
        })
        let internalOligo = String(template.dropFirst(40).prefix(18))
        return """
            SEQUENCE_ID=\(resultID)
            PRIMER_PAIR_NUM_RETURNED=1
            PRIMER_LEFT_0=5,20
            PRIMER_LEFT_0_SEQUENCE=\(left)
            PRIMER_LEFT_0_TM=60.1
            PRIMER_LEFT_0_GC_PERCENT=50
            PRIMER_RIGHT_0=99,21
            PRIMER_RIGHT_0_SEQUENCE=\(right)
            PRIMER_RIGHT_0_TM=60.2
            PRIMER_RIGHT_0_GC_PERCENT=48
            PRIMER_INTERNAL_0=40,18
            PRIMER_INTERNAL_0_SEQUENCE=\(internalOligo)
            PRIMER_INTERNAL_0_TM=59
            PRIMER_INTERNAL_0_GC_PERCENT=33
            PRIMER_PAIR_0_PRODUCT_SIZE=95
            =
            """
    }

    // MARK: - PrimalScheme3, through PrimalScheme3DesignPipeline

    static func primalScheme3(_ spelling: SpelledProject.Spelling) async throws -> SpelledRun {
        let project = try SpelledProject(spelling)
        try project.makeAnalysesFolder()
        try Data(">target\nACGTACGTACGT\n".utf8).write(to: project.physical.appendingPathComponent("target.fasta"))
        let input = project.spelled.appendingPathComponent("target.fasta")
        let seen = OSAllocatedUnfairLock<String?>(initialState: nil)
        let pipeline = PrimalScheme3DesignPipeline(
            runner: { command in
                if let index = command.arguments.firstIndex(of: "--output") {
                    seen.withLock { $0 = command.arguments[index + 1] }
                }
                return try primalNativeFixture(command)
            },
            writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
        let request = PrimalScheme3DesignRequest(
            inputURLs: [input], destinationURL: project.spelledDestination,
            options: .init(ampliconSize: 400, poolCount: 2), grouping: .independent,
            invocation: .init(
                argv: ["lungfish", "primer", "design", input.path], callerVersion: "test", explicitOptions: [:],
                runtimeIdentity: .init()),
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)])
        do {
            let url = try await pipeline.run(request: request)
            return SpelledRun(project: project, result: .success(url), runnerPath: seen.withLock { $0 })
        } catch {
            return SpelledRun(project: project, result: .failure(error), runnerPath: seen.withLock { $0 })
        }
    }

    private static func primalNativeFixture(_ command: PrimalScheme3Command) throws -> PrimalScheme3Execution {
        guard let outputIndex = command.arguments.firstIndex(of: "--output") else { throw CocoaError(.fileReadUnknown) }
        let output = URL(fileURLWithPath: command.arguments[outputIndex + 1])
        try FileManager.default.createDirectory(at: output.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let version = PrimalScheme3DesignPipeline.toolVersion
        let config: [String: Any] = [
            "version": version, "mode": "equal", "amplicon_size": 400, "n_pools": 2,
            "amplicon_size_min": 360, "amplicon_size_max": 440, "amplicon_size_metric": "legacy-pairing",
            "terminal_gap_policy": "observed-only", "discovery_core_count": 1,
            "discovery_backend": "python-observed-only",
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: output.appendingPathComponent("config.json"))
        try Data("fixture\t0\t4\tprimer\t1\t+\tACGT\n".utf8).write(to: output.appendingPathComponent("primer.bed"))
        try Data(">fixture\nACGT\n".utf8).write(to: output.appendingPathComponent("reference.fasta"))
        try Data([0, 1, 255]).write(to: output.appendingPathComponent("nested/extra.dat"))
        return PrimalScheme3Execution(
            argv: ["/fixture/primalscheme3"] + command.arguments, stdout: "fixture output", stderr: "", exitStatus: 0,
            version: version, runtime: .init(executablePath: "/fixture/primalscheme3"), startedAt: Date(),
            endedAt: Date())
    }

    // MARK: - Shared helpers

    /// The command as the adapter records it, with `run.py` spelled another way.
    static func recording(_ command: PrimerSchemeAdapterCommand, runPy: String) -> PrimerSchemeAdapterCommand {
        var arguments = command.arguments
        arguments[0] = runPy
        return PrimerSchemeAdapterCommand(
            executableURL: command.executableURL, arguments: arguments, request: command.request,
            requestURL: command.requestURL, adapterDirectoryURL: command.adapterDirectoryURL,
            outputDirectoryURL: command.outputDirectoryURL, workingDirectoryURL: command.workingDirectoryURL,
            environment: command.environment)
    }

    /// The path `realpath(3)` gives, as Python's `Path.resolve()` does, which keeps `/private`.
    static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
