// BuildDbCommand+Provenance.swift - Provenance sidecars for build-db outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The classifiers `build-db` records provenance for. The word it takes comes from the registry's descriptor.
enum BuildDbProvenanceTool {
    case taxTriage
    case esViritu
    case kraken2

    /// The registry kind this classifier is.
    var analysisToolID: AnalysisToolID {
        switch self {
        case .taxTriage: return .taxtriage
        case .esViritu: return .esviritu
        case .kraken2: return .kraken2
        }
    }

    /// The word `lungfish build-db` takes, which the registry's descriptor holds. A kind with no token
    /// falls back to its id, as the app's router does.
    var rawValue: String {
        AnalysisToolRegistry.descriptor(for: analysisToolID)?.buildDatabaseToken ?? analysisToolID.rawValue
    }

    var workflowName: String {
        "lungfish build-db \(rawValue)"
    }
}

extension BuildDbCommand {
    static func buildDbInputRecords(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        sampleDirectories: [URL] = []
    ) -> [FileRecord] {
        let roots = buildDbSearchRoots(tool: tool, resultURL: resultURL, sampleDirectories: sampleDirectories)
        let urls = roots.flatMap { root in
            buildDbFileURLs(in: root) { url in
                isBuildDbSourceFile(url, for: tool)
            }
        }
        let records = urls.map { ProvenanceRecorder.fileRecord(url: $0, role: role(for: $0, tool: tool)) }
        if records.isEmpty {
            return [ProvenanceRecorder.fileRecord(url: resultURL, format: .unknown, role: .input)]
        }
        return records
    }

    /// Records one build-db run beside each output and, unless `writesFolderRecord` is false, in the result
    /// folder when no other workflow's record is there. Returns the run's record. A record problem that
    /// leaves the run standing goes to `events.warning`.
    @discardableResult
    static func recordBuildDbProvenance(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        runClock: ProvenanceRunClock,
        inputRecords: [FileRecord],
        exitStatus: Int = 0,
        stderr: String? = nil,
        sampleDirectories: [URL] = [],
        additionalSteps: [ProvenanceStep] = [],
        writtenFiles: [ProvenanceFileDescriptor] = [],
        includeOutputRecords: Bool = true,
        writesFolderRecord: Bool = true,
        events: BuildDbEventSink
    ) async throws -> ProvenanceEnvelope {
        let startedAt = runClock.startedAt
        let completedAt = runClock.now
        let outputDescriptors = includeOutputRecords
            ? buildDbOutputRecords(tool: tool, dbURL: dbURL, resultURL: resultURL, written: writtenFiles)
            : []
        let command = buildDbReplayArgv(
            tool: tool,
            resultURL: resultURL,
            force: force,
            noCleanup: noCleanup,
            globalOptions: globalOptions,
            sampleDirectories: sampleDirectories
        )
        let toolName = tool.workflowName
        let toolVersion = WorkflowRun.currentAppVersion
        let wallTime = max(0, completedAt.timeIntervalSince(startedAt))
        let inputDescriptors = inputRecords.map { ProvenanceFileDescriptor(fileRecord: $0) }
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: command,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: exitStatus,
            wallTimeSeconds: wallTime,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )

        var builder = ProvenanceRunBuilder(
            workflowName: toolName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: toolVersion
        )
        .argv(command)
        .options(
            explicit: buildDbExplicitOptions(
                resultURL: resultURL,
                force: force,
                noCleanup: noCleanup,
                globalOptions: globalOptions,
                sampleDirectories: sampleDirectories
            ),
            defaults: buildDbDefaultOptions(),
            resolved: buildDbResolvedOptions(
                tool: tool,
                resultURL: resultURL,
                dbURL: dbURL,
                force: force,
                noCleanup: noCleanup,
                globalOptions: globalOptions,
                sampleDirectories: sampleDirectories
            )
        )
        .runtime(ProvenanceRuntimeIdentity())

        for additionalStep in additionalSteps {
            builder = builder.step(additionalStep)
        }
        builder = builder.step(step)

        let completed = try builder.complete(
            exitStatus: exitStatus,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )
        // A step keeps each file as it was when the step ran and a removal step names what went, so the run
        // level of the record and of each sidecar names only what is on disk (2.8 B3). That holds for
        // build-db esviritu, which moves each BAM out of `_temp/` and marks duplicates in place (2.10 A39),
        // and for build-db kraken2, which removes the raw per-read output and rewrites each result sidecar
        // in place (2.10 FXK2). The taxtriage run level keeps the names that the legacy GUI route's cleanup
        // removed, a correct difference (BIO's Q3 in the A39 review). The top reports it names that are gone
        // come from that cleanup, which records no removal step, while the executor keeps `top/`, and its
        // steps still name them, so the parity entry stays with the GUI route (TaxTriageParityKnownDifferences).
        // It drops the bytes a removal step names, the BAM that the unique-read pass marked in place and the
        // index it replaced, so no record names bytes that no file holds (Q32 X1, BIO's ruling F1).
        let envelope = tool == .taxTriage ? completed.droppingReplacedRunLevelFiles() : completed.droppingRemovedRunLevelFiles()

        let writer = ProvenanceWriter()
        if writesFolderRecord {
            try writeFolderProvenance(envelope, tool: tool, resultURL: resultURL, writer: writer, events: events)
        }
        for output in envelope.outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            // A BAM or index of `build-db esviritu` keeps the steps of its own lineage and none of the probes and
            // counts of the other BAMs, which made each of its sidecars as large as the database's. The database's
            // sidecar keeps today's projection, with every step without outputs and so every read count (ARCH
            // ruling Q-S2, pre-2.12).
            let focused = tool == .esViritu && isEsVirituBAMFile(outputURL)
                ? envelope.focusedOnLineage(of: output)
                : envelope.focusedOnOutput(output)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                guard mayReplaceProvenance(ProvenanceRecorder.loadEnvelope(from: outputURL), tool: tool) else {
                    continue
                }
                try writer.write(focused, to: outputURL)
            } else {
                let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
                guard mayReplaceProvenance(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL), tool: tool) else {
                    continue
                }
                try writer.write(focused, toSidecar: sidecarURL)
            }
        }
        return envelope
    }

    /// Whether build-db may write over `existing`: only when there is none or
    /// it is an earlier envelope from this same build-db tool. A result
    /// folder's provenance describes the classifier run that produced it
    /// (Kraken 2 and Bracken versions, database, parameters); building the
    /// viewer's SQLite index must never replace that record.
    static func mayReplaceProvenance(_ existing: ProvenanceEnvelope?, tool: BuildDbProvenanceTool) -> Bool {
        guard let existing else { return true }
        return existing.workflowName == tool.workflowName
    }

    /// Writes the result folder's `.lungfish-provenance.json` only when doing
    /// so cannot destroy the classifier run's record.
    ///
    /// - Another workflow's envelope (the classifier run): left untouched. The
    ///   build-db run is still recorded in `kraken2.sqlite`'s own sidecar.
    /// - A single Kraken 2 result folder with no envelope, or with one an
    ///   older build-db wrote over the run's record: the run envelope is
    ///   rebuilt from `classification-result.json`.
    /// - Otherwise (a bare or imported folder, a batch root, or a failed
    ///   rebuild): the build-db envelope is written, as before.
    private static func writeFolderProvenance(
        _ envelope: ProvenanceEnvelope,
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        writer: ProvenanceWriter,
        events: BuildDbEventSink
    ) throws {
        let existing = ProvenanceRecorder.loadEnvelope(from: resultURL)
        guard mayReplaceProvenance(existing, tool: tool) else { return }
        if tool == .kraken2,
           FileManager.default.fileExists(
               atPath: resultURL.appendingPathComponent(ClassificationResult.sidecarFilename).path
           ) {
            do {
                let restored = try ClassificationProvenanceReconstructor.reconstructEnvelope(resultDirectory: resultURL)
                try writer.write(restored, to: resultURL)
                return
            } catch {
                events.warning("Warning: could not rebuild the Kraken 2 run provenance from classification-result.json: \(error)")
            }
        }
        try writer.write(envelope, to: resultURL)
    }

    static func recordBuildDbFailureProvenanceIfNeeded(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        runClock: ProvenanceRunClock,
        inputRecords: [FileRecord],
        error: Error,
        sampleDirectories: [URL] = [],
        additionalSteps: [ProvenanceStep] = [],
        includeOutputRecords: Bool = true,
        writesFolderRecord: Bool = true,
        events: BuildDbEventSink
    ) async {
        do {
            try await recordBuildDbProvenance(
                tool: tool,
                resultURL: resultURL,
                dbURL: dbURL,
                force: force,
                noCleanup: noCleanup,
                globalOptions: globalOptions,
                runClock: runClock,
                inputRecords: inputRecords,
                exitStatus: 1,
                stderr: error.localizedDescription,
                sampleDirectories: sampleDirectories,
                additionalSteps: additionalSteps,
                includeOutputRecords: includeOutputRecords,
                writesFolderRecord: writesFolderRecord,
                events: events
            )
        } catch {
            events.warning("Warning: could not write failed build-db provenance: \(error.localizedDescription)")
        }
    }

    /// The outputs of the run's own step: the database, the BAMs and indexes that `build-db esviritu` moved and marked,
    /// and `written`, the files the run's cleanup wrote or rewrote with the digests its steps state. `build-db kraken2`
    /// names no file it finds, since a per-read output, index or result sidecar that its cleanup did not write is not
    /// its output. Such a file is an input of the step with its digest (`buildDbInputRecords`), and no sidecar is
    /// written beside it, so it never gets `build-db` as its producer (2.11 B62, R-PRODUCER, BIO 6).
    private static func buildDbOutputRecords(
        tool: BuildDbProvenanceTool,
        dbURL: URL,
        resultURL: URL,
        written: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var urls = [dbURL]
        if tool == .esViritu {
            urls.append(contentsOf: buildDbFileURLs(in: resultURL, matching: isEsVirituBAMFile))
        }
        let found = uniqueExistingFileURLs(urls).map { url in
            ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: url, role: role(for: url, tool: tool, output: true)))
        }
        var seen = Set(found.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        return found + written.filter { file in
            FileManager.default.fileExists(atPath: file.path)
                && seen.insert(URL(fileURLWithPath: file.path).standardizedFileURL.path).inserted
        }
    }

    /// Whether `url` is a BAM or BAM index in a `bams/` folder, which `build-db esviritu` moved there and names
    /// as an output of its run.
    private static func isEsVirituBAMFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathComponents.contains("bams")
            && (name.hasSuffix(".bam") || name.hasSuffix(".bam.bai") || name.hasSuffix(".bam.csi"))
    }

    private static func buildDbSearchRoots(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        sampleDirectories: [URL]
    ) -> [URL] {
        guard tool == .kraken2, !sampleDirectories.isEmpty else {
            return [resultURL]
        }
        return sampleDirectories.map(\.standardizedFileURL)
    }

    private static func buildDbFileURLs(
        in root: URL,
        matching predicate: (URL) -> Bool
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            guard !isBuildDbProvenanceOrDatabaseFile(url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true, predicate(url) else { return nil }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private static func uniqueExistingFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    private static func isBuildDbSourceFile(_ url: URL, for tool: BuildDbProvenanceTool) -> Bool {
        let name = url.lastPathComponent
        switch tool {
        case .taxTriage:
            return name == "multiqc_confidences.txt"
                || name.hasSuffix(".top_report.tsv")
                || name.hasSuffix(".combined.gcfmap.tsv")
                || name.hasSuffix(".bam")
                || name.hasSuffix(".bam.bai")
                || name.hasSuffix(".bam.csi")
        case .esViritu:
            return name.hasSuffix(".detected_virus.info.tsv")
                || name.hasSuffix(".virus_coverage_windows.tsv")
                || name.hasSuffix(".detected_virus.assembly_summary.tsv")
                || name.hasSuffix(".bam")
                || name.hasSuffix(".bam.bai")
                || name.hasSuffix(".bam.csi")
        case .kraken2:
            return name.hasSuffix(".kreport")
                || name == "classification.bracken"
                || name == "classification.kraken"
                || name == "classification.kraken.gz"
                || name == "classification.kraken.idx.sqlite"
                || name == "classification.kraken.gz.idx.sqlite"
                || name == "classification-result.json"
        }
    }

    private static func isBuildDbProvenanceOrDatabaseFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let generatedDatabaseNames: Set<String> = ["taxtriage.sqlite", "esviritu.sqlite", "kraken2.sqlite"]
        let generatedDatabaseJournals = generatedDatabaseNames.flatMap { name in
            ["\(name)-shm", "\(name)-wal"]
        }
        return name == ProvenanceRecorder.provenanceFilename
            || name.hasSuffix(".lungfish-provenance.json")
            || generatedDatabaseNames.contains(name)
            || generatedDatabaseJournals.contains(name)
    }

    private static func role(
        for url: URL,
        tool: BuildDbProvenanceTool,
        output: Bool = false
    ) -> FileRole {
        if output {
            if url.lastPathComponent.hasSuffix(".bai")
                || url.lastPathComponent.hasSuffix(".csi")
                || url.lastPathComponent.hasSuffix(".idx.sqlite") {
                return .index
            }
            return .output
        }
        let name = url.lastPathComponent
        if name.hasSuffix(".bai") || name.hasSuffix(".csi") || name.hasSuffix(".idx.sqlite") {
            return .index
        }
        if name.hasSuffix(".kreport") || name.hasSuffix(".top_report.tsv") || name == "multiqc_confidences.txt" {
            return .report
        }
        _ = tool
        return .input
    }

    private static func buildDbReplayArgv(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        sampleDirectories: [URL] = []
    ) -> [String] {
        var argv = [CLICommandIdentity.executableName, "build-db", tool.rawValue, resultURL.path]
        if force { argv.append("--force") }
        if noCleanup { argv.append("--no-cleanup") }
        if tool == .kraken2 {
            for sampleDirectory in sampleDirectories {
                argv += ["--sample-dir", sampleDirectory.path]
            }
        }
        if globalOptions.outputFormat != .text {
            argv += ["--format", globalOptions.outputFormat.rawValue]
        }
        if globalOptions.quiet { argv.append("--quiet") }
        if globalOptions.verbosity > 0 {
            argv.append("-" + String(repeating: "v", count: globalOptions.verbosity))
        }
        if globalOptions.showProgress { argv.append("--progress") }
        if globalOptions.noProgress { argv.append("--no-progress") }
        if globalOptions.debug { argv.append("--debug") }
        if let logFile = globalOptions.logFile {
            argv += ["--log-file", logFile]
        }
        if globalOptions.noColor { argv.append("--no-color") }
        if let threads = globalOptions.threads {
            argv += ["--threads", String(threads)]
        }
        return argv
    }

    private static func buildDbExplicitOptions(
        resultURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        sampleDirectories: [URL] = []
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "resultDir": .file(resultURL)
        ]
        if force { options["force"] = .boolean(true) }
        if noCleanup { options["noCleanup"] = .boolean(true) }
        if !sampleDirectories.isEmpty {
            options["sampleDirs"] = .array(sampleDirectories.map { .file($0.standardizedFileURL) })
        }
        if globalOptions.outputFormat != .text { options["outputFormat"] = .string(globalOptions.outputFormat.rawValue) }
        if globalOptions.quiet { options["quiet"] = .boolean(true) }
        if globalOptions.verbosity > 0 { options["verbosity"] = .integer(globalOptions.verbosity) }
        if globalOptions.showProgress { options["showProgress"] = .boolean(true) }
        if globalOptions.noProgress { options["noProgress"] = .boolean(true) }
        if globalOptions.debug { options["debug"] = .boolean(true) }
        if let logFile = globalOptions.logFile { options["logFile"] = .file(URL(fileURLWithPath: logFile)) }
        if globalOptions.noColor { options["noColor"] = .boolean(true) }
        if let threads = globalOptions.threads { options["threads"] = .integer(threads) }
        return options
    }

    private static func buildDbDefaultOptions() -> [String: ParameterValue] {
        [
            "force": .boolean(false),
            "noCleanup": .boolean(false),
            "outputFormat": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false),
            "verbosity": .integer(0),
            "showProgress": .boolean(false),
            "noProgress": .boolean(false),
            "debug": .boolean(false),
            "logFile": .null,
            "noColor": .boolean(false),
            "threads": .null,
            "sampleDirs": .array([]),
        ]
    }

    private static func buildDbResolvedOptions(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        sampleDirectories: [URL] = []
    ) -> [String: ParameterValue] {
        var resolved: [String: ParameterValue] = [
            "tool": .string(tool.rawValue),
            "database": .file(dbURL),
            "cleanupPerformed": .boolean(!noCleanup),
            "outputFormat": .string(globalOptions.outputFormat.rawValue),
            "quiet": .boolean(globalOptions.quiet),
            "verbosity": .integer(globalOptions.verbosity),
            "showProgress": .boolean(globalOptions.showProgress),
            "noProgress": .boolean(globalOptions.noProgress),
            "debug": .boolean(globalOptions.debug),
            "noColor": .boolean(globalOptions.noColor),
            "threads": globalOptions.threads.map(ParameterValue.integer) ?? .null,
            "effectiveThreads": .integer(globalOptions.effectiveThreads),
        ]
        if tool == .kraken2 {
            resolved["sampleDirs"] = .array(sampleDirectories.map { .file($0.standardizedFileURL) })
        }

        if tool != .kraken2 {
            if let samtoolsPath = BuildDbCommand.locateSamtools() {
                resolved["samtoolsAvailable"] = .boolean(true)
                resolved["samtoolsPath"] = .file(URL(fileURLWithPath: samtoolsPath))
                resolved["samtoolsVersion"] = .string(detectSamtoolsVersion(at: samtoolsPath))
            } else {
                resolved["samtoolsAvailable"] = .boolean(false)
                resolved["samtoolsPath"] = .null
                resolved["samtoolsVersion"] = .null
            }
        }

        return CLIProvenanceSupport.resolvedOptions(
            explicit: buildDbExplicitOptions(
                resultURL: resultURL,
                force: force,
                noCleanup: noCleanup,
                globalOptions: globalOptions,
                sampleDirectories: sampleDirectories
            ),
            defaults: buildDbDefaultOptions(),
            resolved: resolved
        )
    }

    static func detectSamtoolsVersion(at path: String) -> String {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["--version"],
            environment: ToolProcessSpec.inheritedEnvironment(),
            label: "\(URL(fileURLWithPath: path).lastPathComponent) --version"
        )

        do {
            // One pipe held both streams before, so the version may print on either one.
            let result = try ToolProcess.runBlocking(spec)
            let output = String(data: result.stdout + result.stderr, encoding: .utf8) ?? ""
            if let firstLine = output.split(separator: "\n").first {
                let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        } catch {
            return "unknown"
        }

        return "unknown"
    }
}
