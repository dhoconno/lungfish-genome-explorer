// ClassifierCLIRouteFixtures.swift - Transcripts and result trees for the classifier CLI route tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10. The route's tests play transcripts written by the real analysis run
// executor, so the lines are the executor's own: its start line, the early `output` line, the
// unit lines, the warning a failed or degraded unit gets, and the last line. A stand-in tool
// writes the result each unit leaves, from the kraken2-mini and esviritu-mini fixtures, and the
// finalize writes the batch manifest and the database line the commands write. A shell script
// plays the transcript in place of `lungfish-cli`, as the commands of lanes A8 and A9 print it.
// When their real transcripts land, the tests switch to them.

import Foundation
import LungfishCore
import LungfishIO
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// What one stand-in classifier unit does under the real executor.
enum StandInClassifierUnit: Sendable, Equatable {
    /// Writes the fixture result and completes.
    case complete
    /// Writes the fixture result with a degraded Bracken profile and completes with a warning, as
    /// a Kraken2 sample whose profile degraded does (E4).
    case degrade(String)
    /// Fails for the reason given, after logging the EsViritu log tail when one is given.
    case fail(String, logTail: String?)
}

/// A Kraken2 or EsViritu tool for the real `AnalysisRunExecutor` that runs no external program.
struct StandInClassifierTool: AnalysisRunTool {
    let tool: CLIClassifierTool
    let units: [(label: String, script: StandInClassifierUnit)]
    let layout: AnalysisRunLayout
    /// The build error of the database, which the finalize reports in today's warning line.
    var databaseFailure: String?
    /// Where the first unit copies the run record, so a test can put it back for a replay.
    var runRecordCopy: URL?
    /// The completion detail of the command's last line. The route reads its own from disk.
    var commandDetail = "the command's own detail"

    var identity: AnalysisRunIdentity {
        tool == .kraken2
            ? AnalysisRunIdentity(toolID: .kraken2, workflowName: "lungfish.classify")
            : AnalysisRunIdentity(toolID: .esviritu, workflowName: "lungfish.esviritu.detect")
    }

    var terminalPolicy: AnalysisRunTerminalPolicy {
        .warnOnFailedUnits
    }

    func plan(
        _ request: AnalysisRunRequest,
        context: AnalysisRunPlanningContext
    ) async throws -> AnalysisRunPlan<StandInClassifierUnit> {
        AnalysisRunPlan(layout: layout, units: units.map { AnalysisRunPlannedUnit(label: $0.label, value: $0.script) })
    }

    func run(
        _ unit: AnalysisRunUnit<StandInClassifierUnit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<URL> {
        if unit.index == 0, let runRecordCopy {
            try? FileManager.default.removeItem(at: runRecordCopy)
            try FileManager.default.copyItem(at: AnalysisRunRecord.url(in: context.rootDirectory), to: runRecordCopy)
        }
        context.log(.info, "Materializing \(unit.label) into the result folder")
        context.progress(0, "Validating configuration...")
        context.progress(0.5, tool == .kraken2 ? "Running Kraken2..." : "Running EsViritu...")
        switch unit.value {
        case .complete:
            try ClassifierRouteFixtures.writeResult(of: tool, sample: unit.sampleName, into: unit.directory)
            try recordStep(of: unit, context: context)
            context.progress(1, tool == .kraken2 ? "Classification complete" : "Detection complete")
            return .completed(unit.directory)
        case .degrade(let reason):
            try ClassifierRouteFixtures.writeResult(of: tool, sample: unit.sampleName, into: unit.directory, degradedReason: reason)
            try recordStep(of: unit, context: context)
            context.progress(1, "Classification complete")
            return .completedWithWarning(unit.directory, reason: reason)
        case .fail(let reason, let logTail):
            if let logTail {
                context.log(.error, CLIClassifierRowEvents.esVirituLogTailHeading + logTail)
            }
            return .failed(reason: reason)
        }
    }

    /// The tool's step with the table it wrote, the scientific output a completed record needs.
    private func recordStep(of unit: AnalysisRunUnit<StandInClassifierUnit>, context: AnalysisRunUnitContext) throws {
        let table = tool == .kraken2
            ? unit.directory.appendingPathComponent("classification.kreport")
            : unit.directory.appendingPathComponent("\(unit.sampleName).detected_virus.info.tsv")
        context.recordStep(ProvenanceStep(
            toolName: tool == .kraken2 ? "kraken2" : "EsViritu",
            toolVersion: "1.0",
            argv: [tool == .kraken2 ? "kraken2" : "EsViritu", table.path],
            inputs: [],
            outputs: [try ProvenanceFileDescriptor.file(url: table, role: .output)],
            exitStatus: 0
        ))
    }

    func finalize(
        _ units: [AnalysisUnitReport<URL>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        var warnings: [String] = []
        if layout == .batchRoot {
            let completed = units.filter(\.outcome.completed)
            let samples = completed.map {
                MetagenomicsBatchSampleRecord(
                    sampleId: $0.sampleName,
                    resultDirectory: $0.directory.lastPathComponent,
                    inputFiles: [],
                    isPairedEnd: false
                )
            }
            let header = MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: Date(), sampleCount: units.count)
            switch tool {
            case .kraken2:
                try MetagenomicsBatchResultStore.saveClassification(
                    ClassificationBatchResultManifest(
                        header: header,
                        goal: "profile",
                        databaseName: "Viral",
                        databaseVersion: "1",
                        summaryTSV: "classification-batch-summary.tsv",
                        samples: samples,
                        completedCount: completed.count,
                        degradedCount: 0,
                        failedCount: units.count - completed.count
                    ),
                    to: context.rootDirectory
                )
            case .esViritu:
                context.progress("Writing the EsViritu batch summary\u{2026}")
                try MetagenomicsBatchResultStore.saveEsViritu(
                    EsVirituBatchResultManifest(header: header, summaryTSV: "esviritu-batch-summary.tsv", samples: samples),
                    to: context.rootDirectory
                )
            }
            context.progress(tool.databaseBuildDetail)
            context.log(.info, "Built database with \(completed.count) rows")
            if let databaseFailure {
                warnings.append(AppDelegate.classificationDatabaseBuildWarning(databaseFailure))
            }
        }
        return AnalysisRunFinalization(completionDetail: commandDetail, warnings: warnings)
    }
}

/// Writes results, runs the executor in process and makes stand-in commands.
enum ClassifierRouteFixtures {
    static let kraken2Sample = "SRR35517702"

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// A project folder with one FASTQ input, `Imports/<name>`.
    static func makeProject(in root: URL, inputs: [String] = ["reads.fastq"]) throws -> (project: URL, inputs: [URL]) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let urls = try inputs.map { name -> URL in
            let url = imports.appendingPathComponent(name)
            try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        return (project, urls)
    }

    /// The fixture result of `tool` in `directory`, a Kraken2 sample of kraken2-mini, with a
    /// degraded Bracken profile for `degradedReason`, or an EsViritu sample of esviritu-mini.
    static func writeResult(of tool: CLIClassifierTool, sample: String, into directory: URL, degradedReason: String? = nil) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        switch tool {
        case .kraken2:
            let source = fixtures.appendingPathComponent("kraken2-mini/\(kraken2Sample)", isDirectory: true)
            for name in ["classification-result.json", "classification.kreport", "classification.kraken"] {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            }
            guard let degradedReason else { return }
            let current = try ClassificationResult.load(from: directory)
            let resolution = BrackenDatabaseCapabilities.resolve(
                catalogID: current.config.databaseCatalogID,
                installationRecipe: current.config.databaseInstallationRecipe,
                request: .automaticDefault
            )
            try ClassificationResult(
                config: current.config,
                tree: current.tree,
                reportURL: current.reportURL,
                outputURL: current.outputURL,
                brackenURL: nil,
                profileOutcome: .degraded(resolution: resolution, reason: .distributionUnavailable, message: degradedReason),
                runtime: current.runtime,
                toolVersion: current.toolVersion,
                provenanceId: current.provenanceId
            ).save(to: directory)
        case .esViritu:
            let source = fixtures.appendingPathComponent("esviritu-mini/SRR35517702/SRR35517702.detected_virus.info.tsv")
            let table = directory.appendingPathComponent("\(sample).detected_virus.info.tsv")
            try fileManager.copyItem(at: source, to: table)
            let config = EsVirituConfig(
                inputFiles: [directory.appendingPathComponent("reads.fastq")],
                isPairedEnd: false,
                sampleName: sample,
                outputDirectory: directory,
                databasePath: directory.appendingPathComponent("db"),
                qualityFilter: true,
                threads: 1,
                extraArguments: [],
                readFormat: .unpaired,
                inputLayout: nil
            )
            try LungfishWorkflow.EsVirituResult(
                config: config,
                detectionURL: table,
                assemblyURL: nil,
                taxProfileURL: nil,
                coverageURL: nil,
                virusCount: 0,
                runtime: 1,
                toolVersion: "1.3.3",
                provenanceId: nil
            ).save(to: directory)
        }
    }

    /// The completion detail today's route builds from the fixture result in `folder`.
    static func expectedKraken2Detail(in folder: URL) throws -> ClassificationSingleOutcomeMetadata {
        ClassificationBatchOutcomePolicy.singleResultMetadata(for: try ClassificationResult.load(from: folder))
    }

    static func expectedEsVirituDetail() throws -> String {
        let detections = try EsVirituDetectionParser.parse(
            url: fixtures.appendingPathComponent("esviritu-mini/SRR35517702/SRR35517702.detected_virus.info.tsv")
        )
        return ClassificationCompletionDetail.esVirituDetection(
            virusCount: detections.count,
            familyCount: Set(detections.compactMap(\.family)).count
        )
    }

    /// Runs `tool` with the real executor into `project`, as the command does for `arguments`,
    /// and returns the lines `--format json` prints and the report.
    static func transcript(
        of tool: StandInClassifierTool,
        project: URL,
        inputs: [URL],
        arguments: [String]
    ) async -> (lines: [String], report: AnalysisRunReport) {
        let lines = LineCollector()
        let report = await AnalysisRunExecutor().execute(
            tool,
            AnalysisRunRequest(
                inputs: inputs,
                destination: .project(project),
                groupsSamples: tool.layout == .batchRoot,
                commandLine: ["lungfish-cli"] + arguments
            ),
            events: .jsonLines { lines.append($0) }
        )
        return (lines.lines, report)
    }

    /// A shell script in place of `lungfish-cli` that prints `lines`, after `standardError` on
    /// standard error, and exits with `exitStatus`. With `go` it prints every line but the last,
    /// waits for `go` to exist, removes `settling` as the command settles a completed folder, and
    /// prints the last line.
    static func standInCLI(
        in folder: URL,
        lines: [String],
        standardError: [String] = [],
        exitStatus: Int32 = 0,
        holdingTheLastLineUntil go: URL? = nil,
        settling runRecord: URL? = nil
    ) throws -> URL {
        let tag = UUID().uuidString
        let head = folder.appendingPathComponent("head-\(tag).ndjson")
        let last = folder.appendingPathComponent("last-\(tag).ndjson")
        let errorText = folder.appendingPathComponent("stderr-\(tag).txt")
        var script = "#!/bin/sh\n"
        if !standardError.isEmpty {
            try (standardError.joined(separator: "\n") + "\n").write(to: errorText, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(errorText.path)' >&2\n"
        }
        if let go {
            try (lines.dropLast().joined(separator: "\n") + "\n").write(to: head, atomically: true, encoding: .utf8)
            try ((lines.last ?? "") + "\n").write(to: last, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(head.path)'\n"
            script += "while [ ! -f '\(go.path)' ]; do /bin/sleep 0.05; done\n"
            if let runRecord {
                script += "/bin/rm -f '\(runRecord.path)'\n"
            }
            script += "/bin/cat '\(last.path)'\n"
        } else {
            try (lines.joined(separator: "\n") + "\n").write(to: head, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(head.path)'\n"
        }
        script += "exit \(exitStatus)\n"
        let url = folder.appendingPathComponent("lungfish-cli-\(tag)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A shell script in place of `lungfish-cli` that prints `lines`, touches `ready` and runs
    /// until SIGTERM. On SIGTERM it records its cancel as the executor's `settle(.cancelled)`
    /// does, by writing `cancelledRecord.record` over `cancelledRecord.runRecord` when given,
    /// touches `terminated`, prints the cancelled run's last line and exits 125, as a command with
    /// `SIGTERMCancellation` does inside the transport's grace. The stand-in writes the record in
    /// place, so the run record keeps its file and a test tells a later rewrite by the app from
    /// the command's own write.
    static func cancellableCLI(
        in folder: URL,
        lines: [String],
        ready: URL,
        terminated: URL,
        lastLine: String,
        cancelledRecord: (record: URL, runRecord: URL)? = nil
    ) throws -> URL {
        let tag = UUID().uuidString
        let head = folder.appendingPathComponent("head-\(tag).ndjson")
        let last = folder.appendingPathComponent("last-\(tag).ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: head, atomically: true, encoding: .utf8)
        try (lastLine + "\n").write(to: last, atomically: true, encoding: .utf8)
        let recordCancel = cancelledRecord.map { "/bin/cat \"\($0.record.path)\" > \"\($0.runRecord.path)\"; " } ?? ""
        let script = """
        #!/bin/sh
        trap '\(recordCancel)/usr/bin/touch "\(terminated.path)"; /bin/cat "\(last.path)"; exit 125' TERM
        /bin/cat '\(head.path)'
        /usr/bin/touch '\(ready.path)'
        while :; do /bin/sleep 0.1; done
        """
        let url = folder.appendingPathComponent("lungfish-cli-\(tag)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The command's cancel record of the running record `running`, made outside the project as
    /// the executor's `settle(.cancelled)` makes it, in `scratch`.
    static func cancelledRecord(of running: URL, in scratch: URL) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let record = AnalysisRunRecord.url(in: scratch)
        try FileManager.default.copyItem(at: running, to: record)
        AnalysisRunRecord.recordOutcome(.cancelled, in: scratch)
        return record
    }

    /// The file system's number of the file at `url`, which an atomic rewrite changes, so a test
    /// tells a rewrite with the same bytes from no write.
    static func fileNumber(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.intValue, url.path)
    }

    /// Every file under `folder` with its bytes, the run record left out when `ignoring` names it.
    static func snapshot(of folder: URL, ignoring ignored: Set<String> = []) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  !ignored.contains(url.lastPathComponent) else { continue }
            files[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
        }
        return files
    }
}

/// Lines collected from the executor's event sink, which delivers from several threads.
final class LineCollector: Sendable {
    private let stored = Mutex<[String]>([])

    func append(_ line: String) {
        stored.withLock { $0.append(line) }
    }

    var lines: [String] {
        stored.withLock { $0 }
    }
}
