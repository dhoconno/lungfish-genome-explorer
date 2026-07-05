// BuildDbCommand+Provenance.swift - Provenance sidecars for build-db outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

enum BuildDbProvenanceTool: String {
    case taxTriage = "taxtriage"
    case esViritu = "esviritu"
    case kraken2

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

    static func recordBuildDbProvenance(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        startedAt: Date,
        inputRecords: [FileRecord],
        exitStatus: Int = 0,
        stderr: String? = nil,
        sampleDirectories: [URL] = []
    ) async throws {
        let completedAt = Date()
        let outputRecords = buildDbOutputRecords(
            tool: tool,
            resultURL: resultURL,
            dbURL: dbURL,
            sampleDirectories: sampleDirectories
        )
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
        let outputDescriptors = outputRecords.map { ProvenanceFileDescriptor(fileRecord: $0) }
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

        let envelope = try ProvenanceRunBuilder(
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
        .step(step)
        .complete(
            exitStatus: exitStatus,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        let writer = ProvenanceWriter()
        try writer.write(envelope, to: resultURL)
        for output in outputRecords {
            let outputURL = URL(fileURLWithPath: output.path)
            let focused = envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output))
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                try writer.write(focused, to: outputURL)
            } else {
                try writer.write(focused, toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
            }
        }
    }

    static func recordBuildDbFailureProvenanceIfNeeded(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        force: Bool,
        noCleanup: Bool,
        globalOptions: GlobalOptions,
        startedAt: Date,
        inputRecords: [FileRecord],
        error: Error,
        sampleDirectories: [URL] = []
    ) async {
        guard !buildDbOutputRecords(
            tool: tool,
            resultURL: resultURL,
            dbURL: dbURL,
            sampleDirectories: sampleDirectories
        ).isEmpty else {
            return
        }

        do {
            try await recordBuildDbProvenance(
                tool: tool,
                resultURL: resultURL,
                dbURL: dbURL,
                force: force,
                noCleanup: noCleanup,
                globalOptions: globalOptions,
                startedAt: startedAt,
                inputRecords: inputRecords,
                exitStatus: 1,
                stderr: error.localizedDescription,
                sampleDirectories: sampleDirectories
            )
        } catch {
            if !globalOptions.quiet {
                fputs("Warning: could not write failed build-db provenance: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func buildDbOutputRecords(
        tool: BuildDbProvenanceTool,
        resultURL: URL,
        dbURL: URL,
        sampleDirectories: [URL] = []
    ) -> [FileRecord] {
        var urls = [dbURL]
        switch tool {
        case .taxTriage:
            break
        case .esViritu:
            urls.append(contentsOf: buildDbFileURLs(in: resultURL) { url in
                let name = url.lastPathComponent
                return url.pathComponents.contains("bams")
                    && (name.hasSuffix(".bam") || name.hasSuffix(".bam.bai") || name.hasSuffix(".bam.csi"))
            })
        case .kraken2:
            urls.append(contentsOf: buildDbSearchRoots(
                tool: tool,
                resultURL: resultURL,
                sampleDirectories: sampleDirectories
            ).flatMap { root in
                buildDbFileURLs(in: root) { url in
                    let name = url.lastPathComponent
                    return name == "classification.kraken"
                        || name == "classification.kraken.idx.sqlite"
                        || name == "classification.kraken.gz"
                        || name == "classification.kraken.gz.idx.sqlite"
                        || name == "classification-result.json"
                }
            })
        }
        return uniqueExistingFileURLs(urls).map { url in
            ProvenanceRecorder.fileRecord(url: url, role: role(for: url, tool: tool, output: true))
        }
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
        var argv = ["lungfish", "build-db", tool.rawValue, resultURL.path]
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

    private static func detectSamtoolsVersion(at path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
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
