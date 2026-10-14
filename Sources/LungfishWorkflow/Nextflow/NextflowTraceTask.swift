// NextflowTraceTask.swift - The tasks of a finished Nextflow run, read from the run's own trace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One task of a Nextflow run's trace, the process it ran and its tag (Phase 2.10 lane A30 M3, ARCH's ruling on M3).
///
/// The reader names no workflow, so every workflow on the engine can read its trace with it. An ignored task is a
/// FAILED row with no COMPLETED or CACHED row of that name after it, which a run that exits 0 leaves only when the
/// task's error strategy is `ignore`. A retry leaves a FAILED row and then a COMPLETED one, so a retried task is not
/// ignored. Nextflow 25's plain log no longer prints the `Error is ignored` note, so the log is not read.
package struct NextflowTraceTask: Sendable, Hashable {
    /// The process path, such as `NFCORE_VIRALRECON:VIRALRECON:CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN`.
    package let processPath: String
    /// The task's tag, such as its sample, or empty for a task with none.
    package let tag: String

    package init(processPath: String, tag: String) {
        self.processPath = processPath
        self.tag = tag
    }

    /// The task a trace's `name` field names. `PATH:PROCESS (tag)` splits at its first ` (`, and a name with no tag
    /// is all process path.
    package init(traceName name: String) {
        if name.hasSuffix(")"), let open = name.range(of: " (") {
            self.init(
                processPath: String(name[..<open.lowerBound]),
                tag: String(name[open.upperBound..<name.index(before: name.endIndex)])
            )
        } else {
            self.init(processPath: name, tag: "")
        }
    }

    /// The last part of the process path, the name a task line shows.
    package var processName: String {
        processPath.split(separator: ":").last.map(String.init) ?? processPath
    }

    /// `<process> (<tag>)`, or `<process>` for a task with no tag, the form a task line takes (W1).
    package var label: String {
        tag.isEmpty ? processName : "\(processName) (\(tag))"
    }

    // MARK: - Reading a trace

    /// The ignored tasks of a trace, each once, in the order of their first FAILED row.
    package static func ignored(inTrace traceText: String) -> [NextflowTraceTask] {
        var order: [String] = []
        var unrecovered: [String: Bool] = [:]
        for row in rows(of: traceText) {
            switch row.status {
            case "FAILED":
                if unrecovered[row.name] == nil { order.append(row.name) }
                unrecovered[row.name] = true
            case "COMPLETED", "CACHED":
                if unrecovered[row.name] != nil { unrecovered[row.name] = false }
            default:
                break
            }
        }
        return order.filter { unrecovered[$0] == true }.map(NextflowTraceTask.init(traceName:))
    }

    /// The tasks of a trace with a COMPLETED or CACHED row, whatever rows follow it.
    package static func succeeded(inTrace traceText: String) -> Set<NextflowTraceTask> {
        Set(rows(of: traceText).filter { $0.status == "COMPLETED" || $0.status == "CACHED" }.map { NextflowTraceTask(traceName: $0.name) })
    }

    /// Each row's task name and upper-case status, in the order Nextflow wrote them. The columns are found by the
    /// header's names, so a run's own `trace.fields` order reads too, and a trace without both columns has no rows.
    private static func rows(of traceText: String) -> [(name: String, status: String)] {
        let lines = traceText.split(whereSeparator: \.isNewline)
        guard let header = lines.first.map(fields(of:)),
              let nameColumn = header.firstIndex(of: "name"),
              let statusColumn = header.firstIndex(of: "status") else {
            return []
        }
        return lines.dropFirst().compactMap { line in
            let values = fields(of: line)
            guard values.count > max(nameColumn, statusColumn), !values[nameColumn].isEmpty else { return nil }
            return (values[nameColumn], values[statusColumn].uppercased())
        }
    }

    private static func fields(of line: Substring) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Finding a run's trace

    /// The start of the name of the trace nf-core writes for each run, `pipeline_info/execution_trace_<time>.txt`
    /// under the results folder.
    package static let nfCoreTracePrefix = "execution_trace"

    /// The newest `execution_trace*.txt` in `folder` written at or after `start`, or nil when there is none.
    ///
    /// A results folder that several runs share holds the traces of earlier runs, which are older than this run's
    /// launch. The bound is 2 s before `start`, for a volume that keeps file times in 2 s steps.
    package static func newestTrace(in folder: URL, writtenSince start: Date) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return nil
        }
        let earliest = start.addingTimeInterval(-2)
        var newest: (url: URL, modified: Date)?
        for file in files where file.lastPathComponent.hasPrefix(nfCoreTracePrefix) && file.pathExtension == "txt" {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= earliest else { continue }
            if newest.map({ modified > $0.modified }) ?? true {
                newest = (file, modified)
            }
        }
        return newest?.url
    }

    // MARK: - The run's warning

    /// The one warning line for every ignored task of a run, UX's words under rules 1, 3 and 5 of the contract's
    /// section 5, or nil when no task was ignored.
    package static func ignoredTasksLine(workflowName: String, tasks: [NextflowTraceTask]) -> String? {
        guard !tasks.isEmpty else { return nil }
        return "Some \(workflowName) tasks failed: \(tasks.map(\.label).joined(separator: ", ")). Their outputs are missing."
    }
}
