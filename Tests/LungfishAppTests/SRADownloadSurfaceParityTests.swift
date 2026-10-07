// SRADownloadSurfaceParityTests.swift - The window and fetch sra download give the same files and provenance for the same run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

/// The acceptance check of lane L1 (sub-phase 2.1): for the same run and the
/// same answers from the archives, the window's SRA download and
/// `lungfish-cli fetch sra download` produce the same files and record the
/// same download provenance, and the files import as the same reads.
///
/// Each case runs both surfaces against fresh copies of one scripted ENA and
/// NCBI (`SRAScriptedArchives`) and the SRA Toolkit's recorded fasterq-dump
/// output (`SRAToolkitRecordedRunner`). The window runs as
/// `startENADownloadTask` runs one run: `SRAWindowRunDownload.stage`, then
/// the `import fastq` command its arguments name, in process, then
/// `writeGUISRAFASTQImportProvenance`. The CLI runs `fetch sra download`, then
/// `import fastq` with the same settings. No test reaches the network or
/// spawns a tool.
///
/// The test compares the FASTQ files by name and bytes, the provenance values both
/// record (`downloadSource`, `preferredSource`, `requestedStrategy`,
/// `selectedStrategy`, `fallbackMessage`, `condaEnvironment`,
/// `layoutWarning`), every download step (tool, version, arguments with the
/// two folders masked, exit status, failed-attempt mark, outputs), and the
/// imported reads and their roles.
final class SRADownloadSurfaceParityTests: XCTestCase {

    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-surface-parity")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAnENAOutageServesTheSameRunThroughTheToolkitOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        try await assertSameRun(run, preference: .ena) { archives in
            archives.takeENADown()
        }
    }

    func testPreferNCBIServesTheSameRunThroughTheToolkitOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let files = try gzippedRecordedFiles(run)
        try await assertSameRun(run, preference: .ncbi) { archives in
            archives.listOnENA(run, .init(files: files))
        }
    }

    func testENAsMirrorServesTheSameRunOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let files = try gzippedRecordedFiles(run)
        let outcome = try await assertSameRun(run, preference: .ena) { archives in
            archives.listOnENA(run, .init(files: files))
        }
        XCTAssertEqual(outcome.source, "ENA")
    }

    func testAnMD5FailureOnENAsMirrorFallsBackTheSameWayOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let files = try gzippedRecordedFiles(run)
        var listed = files.map { SRAScriptedArchives.md5($0.data) }
        listed[2] = String(repeating: "0", count: 32)
        let outcome = try await assertSameRun(run, preference: .ena) { archives in
            archives.listOnENA(run, .init(files: files, listedMD5s: listed))
        }
        XCTAssertEqual(outcome.source, "SRA Toolkit (ENA mirror incomplete)")
        XCTAssertEqual(outcome.failedSteps, ["https-download", "https-download"], "the two files that arrived are a failed attempt")
    }

    func testAToolkitFailureUnderPreferNCBIFallsBackToENATheSameWayOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let files = try gzippedRecordedFiles(run)
        let outcome = try await assertSameRun(run, preference: .ncbi, toolkit: failingFasterqDump) { archives in
            archives.listOnENA(run, .init(files: files))
        }
        XCTAssertEqual(outcome.source, "ENA (SRA Toolkit failed)")
        XCTAssertEqual(outcome.failedSteps, ["prefetch", "fasterq-dump"])
    }

    func testASingleEndRunNCBIListsAsPairedWarnsTheSameWayOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.singleEndRun
        let outcome = try await assertSameRun(run, preference: .ena) { archives in
            archives.takeENADown()
            archives.listOnNCBI(run, layout: "PAIRED")
        }
        XCTAssertEqual(outcome.layoutWarning, "NCBI lists \(run) as paired but only one read file arrived; imported as single-end reads")
    }

    func testARunNeitherArchiveServesFailsWithTheSameLineOnBothSurfaces() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let window = SRAScriptedArchives()
        let cli = SRAScriptedArchives()
        for archives in [window, cli] {
            archives.takeENADown()
        }

        var windowError: String?
        do {
            _ = try await windowDownload(run, archives: window, preference: .ena, toolkit: failingPrefetch)
        } catch {
            windowError = error.localizedDescription
        }
        var cliError: String?
        do {
            _ = try await cliDownload(run, archives: cli, preference: .ena, toolkit: failingPrefetch)
        } catch {
            cliError = error.localizedDescription
        }

        let windowLine = try XCTUnwrap(windowError)
        XCTAssertFalse(windowLine.contains("\n"), windowLine)
        XCTAssertEqual(cliError, "Network error: \(windowLine)", "the CLI's line is the window's with the CLI's prefix")
    }

    // MARK: - The comparison

    struct Outcome {
        let source: String?
        let layoutWarning: String?
        let failedSteps: [String]
    }

    /// Runs `run` on both surfaces against archives `script` sets up, asserts
    /// that they give the same files, provenance and imported reads, and
    /// returns what they agreed on.
    @discardableResult
    private func assertSameRun(
        _ run: String,
        preference: SRADownloadSourcePreference,
        toolkit: SRAToolkitRunner? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        script: (SRAScriptedArchives) throws -> Void
    ) async throws -> Outcome {
        let windowArchives = SRAScriptedArchives()
        let cliArchives = SRAScriptedArchives()
        try script(windowArchives)
        try script(cliArchives)
        let toolkit = toolkit ?? recorded.runner

        let window = try await windowDownload(run, archives: windowArchives, preference: preference, toolkit: toolkit)
        let cli = try await cliDownload(run, archives: cliArchives, preference: preference, toolkit: toolkit)

        // The same files, byte for byte.
        XCTAssertEqual(window.files.keys.sorted(), cli.files.keys.sorted(), "file names", file: file, line: line)
        for (name, data) in window.files {
            XCTAssertEqual(data, cli.files[name], "\(name) differs", file: file, line: line)
        }

        // The same download provenance.
        let shared = ["downloadSource", "preferredSource", "requestedStrategy", "selectedStrategy",
                      "fallbackMessage", "condaEnvironment", "layoutWarning"]
        for key in shared {
            XCTAssertEqual(window.provenance.parameters[key], cli.provenance.parameters[key], key, file: file, line: line)
        }
        let windowSteps = window.provenance.steps.filter { Self.downloadTools.contains($0.toolName) }
        let cliSteps = Array(cli.provenance.steps.dropLast())
        XCTAssertEqual(cli.provenance.steps.last?.toolName, CLICommandIdentity.executableName, file: file, line: line)
        // The window's record sits in a project, so it was written with
        // portable paths and resolves the ones that still exist on load. The
        // CLI's sits in a plain folder and keeps real paths. Both are compared
        // in the window's portable form.
        let context = PortablePath.Context.forFile(at: window.bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertEqual(
            windowSteps.map { Self.comparable($0, folder: window.folder, context: context) },
            cliSteps.map { Self.comparable($0, folder: cli.folder, context: context) },
            "download steps",
            file: file,
            line: line
        )

        // The same reads, in the same roles, once imported.
        XCTAssertEqual(window.metadata.readClassification?.pairedReadCount, cli.metadata.readClassification?.pairedReadCount, file: file, line: line)
        XCTAssertEqual(window.metadata.readClassification?.unpairedReadCount, cli.metadata.readClassification?.unpairedReadCount, file: file, line: line)
        let windowReads = try await FASTQReader(validateSequence: false).readAll(from: window.fastq)
        let cliReads = try await FASTQReader(validateSequence: false).readAll(from: cli.fastq)
        XCTAssertEqual(windowReads, cliReads, "imported reads", file: file, line: line)
        XCTAssertFalse(windowReads.isEmpty, file: file, line: line)

        let failed = windowSteps.filter { $0.resolvedOptions?["attempt"] == .string("failed") }.map(\.toolName)
        if case .string(let source)? = window.provenance.parameters["downloadSource"],
           case .string(let warning)? = window.provenance.parameters["layoutWarning"] {
            return Outcome(source: source, layoutWarning: warning, failedSteps: failed)
        }
        if case .string(let source)? = window.provenance.parameters["downloadSource"] {
            return Outcome(source: source, layoutWarning: nil, failedSteps: failed)
        }
        return Outcome(source: nil, layoutWarning: nil, failedSteps: failed)
    }

    private static let downloadTools: Set = ["https-download", "prefetch", "fasterq-dump"]

    /// A step with every path in its portable form under `context`, the
    /// run's download folder and fasterq-dump's temporary folder masked, and
    /// its wall times left out.
    private static func comparable(_ step: StepExecution, folder: URL, context: PortablePath.Context) -> String {
        let folderForm = PortablePath.sanitize(path: folder.path, context: context)
        func masked(_ text: String) -> String {
            let portable = text.hasPrefix("/") ? PortablePath.sanitize(path: text, context: context) : text
            return portable.replacingOccurrences(of: folderForm, with: "<OUT>")
                .replacingOccurrences(of: #"fasterq-[0-9A-Fa-f-]{36}"#, with: "fasterq-<UUID>", options: .regularExpression)
        }
        let outputs = step.outputs.map { masked($0.path) }
        let inputs = step.inputs.map { masked($0.path) }
        return [
            step.toolName,
            step.toolVersion,
            step.command.map(masked).joined(separator: " "),
            "exit \(step.exitCode.map(String.init) ?? "nil")",
            "attempt \(step.resolvedOptions?["attempt"].map { "\($0)" } ?? "served")",
            "in \(inputs.joined(separator: ","))",
            "out \(outputs.joined(separator: ","))",
        ].joined(separator: " | ")
    }

    // MARK: - The two surfaces

    struct SurfaceRun {
        /// The folder the download wrote to, masked in the comparison.
        let folder: URL
        let files: [String: Data]
        let provenance: WorkflowRun
        let metadata: PersistedFASTQMetadata
        let fastq: URL
        /// The bundle the run imported into.
        let bundle: URL
    }

    /// One run of the window's SRA download, as `startENADownloadTask` runs
    /// each run of a batch.
    private func windowDownload(
        _ run: String,
        archives: SRAScriptedArchives,
        preference: SRADownloadSourcePreference,
        toolkit: SRAToolkitRunner
    ) async throws -> SurfaceRun {
        let base = root.appendingPathComponent("window", isDirectory: true)
        let sra = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: toolkit)
        let traces = SRAGUIDownloadTraceCollector()
        let staged = try await SRAWindowRunDownload.stage(
            accession: run,
            preference: preference,
            lookUpNCBIRun: { await sra.ncbiRunInfo(forRun: run) },
            in: base.appendingPathComponent("batch", isDirectory: true),
            lookUpRoute: { try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: run) },
            enaRecordWait: .seconds(10),
            mirrorFile: { url, _, _ in try await archives.mirrorFile(url) },
            toolkit: { _, folder in
                try await sra.downloadFASTQ(accession: run, outputDir: folder, trace: { traces.record($0) })
            }
        )
        defer { staged.removeFolder() }
        let files = try Dictionary(uniqueKeysWithValues: staged.reads.files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })

        let project = base.appendingPathComponent("Project.lungfish", isDirectory: true)
        let arguments = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: Self.importConfiguration(staged.reads.files),
            r1: staged.reads.r1,
            r2: staged.reads.r2,
            unpaired: staged.reads.unpaired,
            projectDirectory: project
        )
        let started = Date()
        try await importFASTQ(arguments, project: project)
        let bundle = project.appendingPathComponent("Imports/\(run).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        try writeGUISRAFASTQImportProvenance(
            accession: run,
            readRecord: staged.download.enaRecord,
            downloadSource: staged.download.source.rawValue,
            preferredSource: staged.download.preference,
            layoutWarning: staged.layoutWarning,
            fallbackMessage: staged.download.fallbackMessage,
            enaDownloadSteps: staged.download.enaSteps,
            toolkitDownloadTraces: traces.steps,
            cliArguments: arguments,
            cliStartedAt: started,
            cliCompletedAt: Date(),
            stagedFASTQFiles: staged.reads.files,
            stagedReadCounts: staged.reads.readCounts(in: metadata.readClassification),
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )
        return SurfaceRun(
            folder: staged.folder,
            files: files,
            provenance: try XCTUnwrap(ProvenanceRecorder.load(from: bundle)),
            metadata: metadata,
            fastq: fastq,
            bundle: bundle
        )
    }

    /// `lungfish-cli fetch sra download <run> --output-dir <folder>`, then
    /// `import fastq` of the files it wrote with the window's settings.
    private func cliDownload(
        _ run: String,
        archives: SRAScriptedArchives,
        preference: SRADownloadSourcePreference,
        toolkit: SRAToolkitRunner
    ) async throws -> SurfaceRun {
        let base = root.appendingPathComponent("cli", isDirectory: true)
        let folder = base.appendingPathComponent("download", isDirectory: true)
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: toolkit)
        let flags = preference == .ncbi ? ["--prefer-source", "ncbi"] : []
        let command = try SRADownloadSubcommand.parse([run, "--output-dir", folder.path, "--quiet"] + flags)
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: folder))
        let downloaded = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(run) && ($0.pathExtension == "fastq" || $0.pathExtension == "gz") }
        let files = try Dictionary(uniqueKeysWithValues: downloaded.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })

        let reads = try SRARunReads(stagedFiles: downloaded, accession: run, listedAsPaired: false)
        let project = base.appendingPathComponent("Project.lungfish", isDirectory: true)
        let arguments = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: Self.importConfiguration(reads.files),
            r1: reads.r1,
            r2: reads.r2,
            unpaired: reads.unpaired,
            projectDirectory: project
        )
        try await importFASTQ(arguments, project: project)
        let bundle = project.appendingPathComponent("Imports/\(run).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        return SurfaceRun(
            folder: folder,
            files: files,
            provenance: provenance,
            metadata: try XCTUnwrap(FASTQMetadataStore.load(for: fastq)),
            fastq: fastq,
            bundle: bundle
        )
    }

    /// Runs the `import fastq` the window's arguments name, in process.
    private func importFASTQ(_ arguments: [String], project: URL) async throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(Array(arguments.prefix(2)), ["import", "fastq"])
        let command = try ImportCommand.FastqSubcommand.parse(Array(arguments.dropFirst(2)) + ["--quiet"])
        try await command.run()
    }

    private static func importConfiguration(_ files: [URL]) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: files,
            detectedPlatform: .illumina,
            confirmedPlatform: .illumina,
            pairingMode: .pairedEnd,
            pairingModeIsUserChoice: false,
            qualityBinning: .none,
            skipClumpify: true,
            clumpingTool: .none,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: .fast
        )
    }

    // MARK: - Fixtures

    /// The recorded run's three files gzipped, in the order ENA lists them,
    /// which puts the file without a suffix first.
    private func gzippedRecordedFiles(_ run: String) throws -> [(name: String, data: Data)] {
        let folder = root.appendingPathComponent("gzip-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = try recorded.recordedFiles(of: run)
            .sorted { ($0.lastPathComponent.contains("_") ? 1 : 0, $0.lastPathComponent) < ($1.lastPathComponent.contains("_") ? 1 : 0, $1.lastPathComponent) }
        return try plain.map { source in
            let name = source.lastPathComponent + ".gz"
            let gzipped = folder.appendingPathComponent(name)
            try KrakenOutputCompactor.gzipCopy(source: source, destination: gzipped)
            return (name, try Data(contentsOf: gzipped))
        }
    }

    /// The recorded toolkit, with a fasterq-dump that fails.
    private var failingFasterqDump: SRAToolkitRunner {
        let recorded = recorded.runner
        return SRAToolkitRunner(prefetch: recorded.prefetch, fasterqDump: recorded.fasterqDump) { executable, arguments in
            if executable == recorded.fasterqDump {
                return SRAToolkitRunner.Result(exitCode: 3, stderr: "fasterq-dump.3.4.1 err: disk full\nfasterq-dump quit with error code 3")
            }
            return try await recorded.run(executable, arguments)
        }
    }

    /// A toolkit whose prefetch fails with several lines of standard error.
    private var failingPrefetch: SRAToolkitRunner {
        let recorded = recorded.runner
        return SRAToolkitRunner(prefetch: recorded.prefetch, fasterqDump: recorded.fasterqDump) { _, _ in
            SRAToolkitRunner.Result(
                exitCode: 3,
                stderr: "2026-10-06T12:00:00 prefetch.3.4.1 err: name not found\n\n2026-10-06T12:00:00 prefetch.3.4.1: 1) failed to download"
            )
        }
    }
}
