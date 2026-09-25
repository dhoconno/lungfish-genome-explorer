// TaxTriageResult+ErroredProcesses.swift - Detect tasks that errored inside a run that exited 0
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// TaxTriage ends some processes with an "ignore" error strategy once their
// retries run out, so Nextflow exits 0 and prints "Pipeline completed
// successfully, but with errored process(es)". A run on human corneal samples
// against Standard-16 showed exactly this: Homo sapiens was a top hit, all of
// GRCh38 was downloaded as a reference, MINIMAP2_ALIGN was killed for memory
// four times per sample, every TASS score was 0, and the Operations panel said
// Completed. The Nextflow 25 plain log does not carry the older
// "NOTE: ... Error is ignored" line that parseIgnoredFailures looks for, so the
// trace file is the primary evidence here.

import Foundation

extension TaxTriageResult {

    // MARK: - Detection

    /// Every errored task of a run that exited 0, merged from the log's
    /// "Error is ignored" notes, trace.txt FAILED rows whose retries ran out,
    /// and the log's `[ERROR]` blocks (which supply the stderr line). When the
    /// log's completion banner reports errored processes and nothing else
    /// names them, one unnamed failure is returned so the run is still marked.
    /// Benign empty-reference alignment failures are dropped
    /// (``sanitizeIgnoredFailures(_:outputDirectory:)``).
    public static func detectErroredProcesses(
        nextflowLogText: String?,
        traceText: String?,
        outputDirectory: URL
    ) -> [TaxTriageIgnoredFailure] {
        var failures: [TaxTriageIgnoredFailure] = []
        var indexByKey: [String: Int] = [:]
        func key(_ failure: TaxTriageIgnoredFailure) -> String {
            failure.processPath + "\u{1}" + failure.taskLabel
        }
        func merge(_ failure: TaxTriageIgnoredFailure) {
            if let index = indexByKey[key(failure)] {
                if failures[index].attempts == nil { failures[index].attempts = failure.attempts }
                if failures[index].diagnostic == nil { failures[index].diagnostic = failure.diagnostic }
            } else {
                indexByKey[key(failure)] = failures.count
                failures.append(failure)
            }
        }

        if let nextflowLogText {
            parseIgnoredFailures(fromNextflowLogText: nextflowLogText).forEach(merge)
        }
        if let traceText {
            parseExhaustedTraceFailures(fromTraceText: traceText).forEach(merge)
        }
        if let nextflowLogText {
            let diagnostics = parseErroredTaskDiagnostics(fromNextflowLogText: nextflowLogText)
            for index in failures.indices where failures[index].diagnostic == nil {
                failures[index].diagnostic = diagnostics[key(failures[index])]
            }
            if failures.isEmpty, reportsErroredProcesses(nextflowLogText: nextflowLogText) {
                let failedCount = parseFailedTaskCount(fromNextflowLogText: nextflowLogText)
                failures.append(TaxTriageIgnoredFailure(
                    processPath: "",
                    processName: "",
                    taskLabel: "",
                    sampleID: nil,
                    exitCode: -1,
                    attempts: failedCount,
                    diagnostic: nil
                ))
            }
        }

        return sanitizeIgnoredFailures(failures, outputDirectory: outputDirectory)
    }

    // MARK: - trace.txt

    /// Tasks whose every trace.txt row is FAILED: Nextflow retried them
    /// (one row per attempt) and none succeeded.
    ///
    /// A task that failed and then COMPLETED (or was CACHED) on a retry is
    /// not an errored task. The trace columns are located by header name, so
    /// custom `trace.fields` orders still parse.
    public static func parseExhaustedTraceFailures(fromTraceText traceText: String) -> [TaxTriageIgnoredFailure] {
        let lines = traceText.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.components(separatedBy: "\t") else { return [] }
        guard let nameColumn = header.firstIndex(of: "name"),
              let statusColumn = header.firstIndex(of: "status") else {
            return []
        }
        let exitColumn = header.firstIndex(of: "exit")

        struct TaskRows {
            var failedAttempts = 0
            var succeeded = false
            var lastExitCode = -1
        }
        var order: [String] = []
        var rowsByName: [String: TaskRows] = [:]

        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count > max(nameColumn, statusColumn) else { continue }
            let name = fields[nameColumn].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if rowsByName[name] == nil {
                order.append(name)
                rowsByName[name] = TaskRows()
            }
            switch fields[statusColumn].trimmingCharacters(in: .whitespaces).uppercased() {
            case "FAILED":
                rowsByName[name]?.failedAttempts += 1
                if let exitColumn, fields.count > exitColumn,
                   let exitCode = Int(fields[exitColumn].trimmingCharacters(in: .whitespaces)) {
                    rowsByName[name]?.lastExitCode = exitCode
                }
            case "COMPLETED", "CACHED":
                rowsByName[name]?.succeeded = true
            default:
                break
            }
        }

        return order.compactMap { name in
            guard let rows = rowsByName[name], rows.failedAttempts > 0, !rows.succeeded else { return nil }
            let (processPath, taskLabel) = splitTaskName(name)
            return TaxTriageIgnoredFailure(
                processPath: processPath,
                processName: processPath.split(separator: ":").last.map(String.init) ?? processPath,
                taskLabel: taskLabel,
                sampleID: taskLabel.isEmpty ? nil : extractSampleID(fromTaskLabel: taskLabel),
                exitCode: rows.lastExitCode,
                attempts: rows.failedAttempts
            )
        }
    }

    /// Splits `PROCESS:PATH (label)` into the process path and the label.
    static func splitTaskName(_ name: String) -> (processPath: String, taskLabel: String) {
        guard name.hasSuffix(")"), let open = name.range(of: " (") else {
            return (name, "")
        }
        let processPath = String(name[..<open.lowerBound])
        let label = String(name[open.upperBound..<name.index(before: name.endIndex)])
        return (processPath, label)
    }

    // MARK: - nextflow.log

    /// The key stderr line of each errored task in a Nextflow 25 plain
    /// (`NXF_ANSI_LOG=false`) log, keyed like ``detectErroredProcesses``
    /// (process path, U+0001, task label). The last attempt wins.
    ///
    /// The block looks like:
    /// ```
    /// [ERROR] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (S1.S1.dwnld.references)
    /// exit: 137
    /// cmd: ...
    /// stderr: WARNING: ... | .../.command.sh: line 23:    45 Killed    minimap2 -ax sr ...
    /// workdir: ...
    /// ```
    public static func parseErroredTaskDiagnostics(fromNextflowLogText logText: String) -> [String: String] {
        var diagnostics: [String: String] = [:]
        var currentKey: String?
        for rawLine in logText.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("[ERROR] ") {
                let name = String(line.dropFirst("[ERROR] ".count)).trimmingCharacters(in: .whitespaces)
                let (processPath, taskLabel) = splitTaskName(name)
                currentKey = processPath.contains(":") || !taskLabel.isEmpty
                    ? processPath + "\u{1}" + taskLabel
                    : nil
                continue
            }
            if line.hasPrefix("[") {
                currentKey = nil
                continue
            }
            if let key = currentKey, line.hasPrefix("stderr:") {
                let stderr = String(line.dropFirst("stderr:".count))
                if let keyLine = keyStderrLine(stderr) {
                    diagnostics[key] = keyLine
                }
            }
        }
        return diagnostics
    }

    /// Picks the line of a task's stderr that explains the failure. Nextflow's
    /// plain log joins stderr lines with " | ". A "Killed" line (the kernel's
    /// OOM kill of a child process) wins; otherwise the last line mentioning
    /// an error; otherwise the last line. The Docker platform-mismatch warning
    /// is never the answer.
    static func keyStderrLine(_ stderr: String, limit: Int = 200) -> String? {
        let lines = stderr
            .components(separatedBy: " | ")
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING: The requested image's platform") }
        func collapsed(_ text: String) -> String {
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return words.count > limit ? String(words.prefix(limit - 3)) + "..." : words
        }
        if let killed = lines.last(where: { $0.contains("Killed") }),
           let range = killed.range(of: "Killed") {
            let command = collapsed(String(killed[range.upperBound...]))
            return command.isEmpty ? "Killed" : "Killed: \(command)"
        }
        if let errorLine = lines.last(where: { $0.localizedCaseInsensitiveContains("error") }) {
            return collapsed(errorLine)
        }
        return lines.last.map(collapsed)
    }

    /// Whether the log's completion banner says some processes errored.
    static func reportsErroredProcesses(nextflowLogText logText: String) -> Bool {
        logText.contains("completed successfully, but with errored process")
    }

    /// The `failed=N` count from Nextflow's plain-log summary
    /// (`[FAILED] completed=22 failed=4 cached=0`). It counts every failed
    /// attempt, retried ones included, so it alone does not prove a task
    /// ran out of retries.
    public static func parseFailedTaskCount(fromNextflowLogText logText: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\bcompleted=\d+\s+failed=(\d+)"#) else { return nil }
        let range = NSRange(logText.startIndex..<logText.endIndex, in: logText)
        guard let match = regex.matches(in: logText, range: range).last,
              let countRange = Range(match.range(at: 1), in: logText) else {
            return nil
        }
        return Int(logText[countRange])
    }

    // MARK: - Presentation

    /// Whether Nextflow exited 0 but some tasks or whole samples failed.
    /// The Operations panel shows such a run as "Completed with Warnings".
    public var completedWithErrors: Bool {
        isSuccess && (hasIgnoredFailures || hasSampleFailures)
    }

    /// A one-paragraph account of the errored tasks, naming each process, its
    /// samples, its attempts, and the key stderr line ("Killed" is reported as
    /// running out of memory), or `nil` when no task errored.
    public var erroredProcessesMessage: String? {
        Self.erroredProcessesMessage(
            for: ignoredFailures,
            hostTaxaExcluded: config.effectiveRemoveTaxids != nil
        )
    }

    /// The first sentence of ``erroredProcessesMessage`` without its trailing
    /// period, short enough for an Operations panel detail line.
    public var erroredProcessesHeadline: String? {
        Self.erroredProcessesHeadline(for: ignoredFailures)
    }

    /// See ``erroredProcessesMessage``.
    public static func erroredProcessesMessage(
        for failures: [TaxTriageIgnoredFailure],
        hostTaxaExcluded: Bool
    ) -> String? {
        guard let headline = erroredProcessesHeadline(for: failures) else { return nil }
        var message = headline + ". "
            + "Results that depend on the failed steps, such as alignments and TASS scores, are missing for the samples named."
        if failures.contains(where: \.isOutOfMemory) {
            message += hostTaxaExcluded
                ? " Raise Max memory and run again."
                : " Raise Max memory, or list the host in Exclude host taxa (9606 for human) so the host genome is not downloaded as an alignment reference."
        }
        return message
    }

    /// See ``erroredProcessesHeadline``.
    public static func erroredProcessesHeadline(for failures: [TaxTriageIgnoredFailure]) -> String? {
        guard !failures.isEmpty else { return nil }

        var order: [String] = []
        var groups: [String: [TaxTriageIgnoredFailure]] = [:]
        for failure in failures {
            if groups[failure.processName] == nil { order.append(failure.processName) }
            groups[failure.processName, default: []].append(failure)
        }

        let clauses = order.map { processName -> String in
            let group = groups[processName] ?? []
            guard !processName.isEmpty else {
                let count = group.compactMap(\.attempts).max()
                return count.map { "Nextflow reported \($0) failed task attempt\($0 == 1 ? "" : "s") without naming the process (see nextflow.log)" }
                    ?? "Nextflow reported errored processes without naming them (see nextflow.log)"
            }
            var clause = "\(processName) failed"
            var samples: [String] = []
            for sampleID in group.compactMap(\.sampleID) where !samples.contains(sampleID) {
                samples.append(sampleID)
            }
            if !samples.isEmpty {
                clause += " for \(samples.joined(separator: ", "))"
            }
            if let attempts = group.compactMap(\.attempts).max(), attempts > 1 {
                clause += " after \(attempts) attempts"
            }
            if group.contains(where: \.isOutOfMemory) {
                clause += " (Killed: out of memory)"
            } else if let diagnostic = group.compactMap(\.diagnostic).first {
                clause += " (\(diagnostic))"
            } else if let exitCode = group.first?.exitCode, exitCode >= 0 {
                clause += " (exit status \(exitCode))"
            }
            return clause
        }

        return "TaxTriage completed with errors: \(clauses.joined(separator: "; "))"
    }
}
