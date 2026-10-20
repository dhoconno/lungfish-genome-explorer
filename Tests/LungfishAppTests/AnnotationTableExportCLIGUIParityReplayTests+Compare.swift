// AnnotationTableExportCLIGUIParityReplayTests+Compare.swift - The sides and the compares of B2's parity class
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

extension AnnotationTableExportCLIGUIParityReplayTests {
    struct CRun {
        let invocation: ViewerExportInvocation
        let outcome: CLIViewerExportRunner.Outcome
        let command: String?
        let detail: String

        var completed: Bool {
            if case .completed = outcome { return true }
            return false
        }
    }

    /// Side C for collected rows. The invocation helper writes the selection, and the begin helper runs the built CLI
    /// behind the row on the shared runner.
    func runC(_ root: URL, _ collected: Collected, format: ScientificTableFormat, output: URL) async throws -> CRun {
        let invocation = try AnnotationTableDrawerView.annotationTableExportInvocation(
            snapshot: collected.snapshot, bundleURL: Self.bundleURL(in: root), tableSelection: collected.table,
            editedValues: collected.editedValues, format: format, outputURL: output
        )
        let failures = AnnotationTableExportFailureCalls()
        let begun = try XCTUnwrap(AnnotationTableDrawerView.beginAnnotationTableExportOperation(
            invocation: invocation,
            rowCount: collected.snapshot.table.rows.count,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ), "the row started")
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        if case .completed = outcome {
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
        }
        return CRun(invocation: invocation, outcome: outcome, command: item?.cliCommand, detail: failures.messages.first ?? item?.detail ?? "no row")
    }

    /// Side A. The in-app writer the panel ran before the leaf, frozen in `AnnotationTableExportFrozenSideA`.
    private func sideA(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        do {
            let collected = try await Self.collectCase(parityCase, in: root)
            try AnnotationTableExportFrozenSideA.export(
                snapshot: collected.snapshot, format: parityCase.format, outputURL: Self.outputURL(in: root, parityCase.format)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(parityCase)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let run = try await runC(
            root, try await Self.collectCase(parityCase, in: root), format: parityCase.format,
            output: Self.outputURL(in: root, parityCase.format)
        )
        if let selection = run.invocation.selection {
            // Side C' replays a command naming this file below its own root, and the record names it as the input.
            try Self.copy(URL(fileURLWithPath: selection), from: root, to: RouteParityHarness.root(of: .cPrime, in: root.deletingLastPathComponent()))
        }
        switch run.outcome {
        case .completed: return RouteParitySideOutcome(end: .completed, detail: run.detail, recordedCommand: run.command)
        case .cancelled: return RouteParitySideOutcome(end: .cancelled, detail: run.detail, recordedCommand: run.command)
        case .failed: return RouteParitySideOutcome(end: .failed, detail: run.detail, recordedCommand: run.command)
        }
    }

    private static func copy(_ file: URL, from root: URL, to otherRoot: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        XCTAssertTrue(path.hasPrefix(rootPath + "/"), "\(path) is below \(rootPath)")
        let target = otherRoot.appendingPathComponent(String(path.dropFirst(rootPath.count + 1)))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it, with R4's compare for xlsx.
    @discardableResult
    func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: deepRoot(parityCase.description),
            fixture: { root in
                if parityCase.derived { try Self.makeDerivedFixture(root, addsChr2: parityCase.addsChr2) } else { try Self.makeFixture(root) }
            },
            sideA: { root in try await self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(parityCase) side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "\(parityCase) side \(side) names no other side's root")
        }
        let cAgainstCPrime = (found[.cAgainstCPrime] ?? []).filter { !Self.variesWithTheArchive($0, parityCase) }
        XCTAssertEqual(cAgainstCPrime.map(\.description), [], "\(parityCase) C against C' differs in nothing outside R4's mask")
        try assertSameOutput(runs.c, runs.cPrime, parityCase, "\(parityCase) C against C'")
        XCTAssertEqual(
            Self.inputs(of: try Self.envelope(in: runs.c.root, parityCase), under: runs.c.root),
            Self.inputs(of: try Self.envelope(in: runs.cPrime.root, parityCase), under: runs.cPrime.root),
            "\(parityCase) C against C', the inputs and their digests"
        )
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// R4 items 1 and 2. An xlsx export's payload, its record's digest and size of it, and `xlsxArchiveArgv` follow
    /// the moment and the temporary name of the archive, so they are compared by `assertXLSXEntriesEqual` or masked.
    private static func variesWithTheArchive(_ difference: RouteParityDifference, _ parityCase: Case) -> Bool {
        guard parityCase.format == .xlsx else { return false }
        let output = outputURL(in: URL(fileURLWithPath: "/"), .xlsx)
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: output).lastPathComponent
        if difference.id.contains(sidecarName) {
            return difference.id.hasSuffix("checksumSHA256") || difference.id.hasSuffix("fileSize")
                || difference.id.contains("xlsxArchiveArgv")
        }
        return difference.id.contains(output.lastPathComponent)
    }

    /// The payload and the record's output facts of two sides, byte for byte with digest and size, or for xlsx entry
    /// by entry (R4 item 1).
    private func assertSameOutput(_ first: RouteParitySideRun, _ second: RouteParitySideRun, _ parityCase: Case, _ label: String) throws {
        let outputFirst = Self.outputURL(in: first.root, parityCase.format)
        let outputSecond = Self.outputURL(in: second.root, parityCase.format)
        let recordFirst = try XCTUnwrap(try Self.envelope(of: outputFirst).output)
        let recordSecond = try XCTUnwrap(try Self.envelope(of: outputSecond).output)
        XCTAssertNotNil(recordFirst.checksumSHA256)
        if parityCase.format == .xlsx {
            try Self.assertXLSXEntriesEqual(outputFirst, outputSecond, label)
            return
        }
        let payloadFirst = try Data(contentsOf: outputFirst)
        XCTAssertEqual(payloadFirst, try Data(contentsOf: outputSecond), "\(label), the payload byte for byte")
        XCTAssertEqual(recordFirst.fileSize, UInt64(payloadFirst.count), label)
        XCTAssertEqual(recordFirst.fileSize, recordSecond.fileSize, "\(label), the output size")
        XCTAssertEqual(recordFirst.checksumSHA256, recordSecond.checksumSHA256, "\(label), the output digest")
    }

    /// R4 item 1. The sorted entry names are equal and each entry's bytes are equal, `xl/workbook.xml` among them.
    static func assertXLSXEntriesEqual(_ first: URL, _ second: URL, _ label: String) throws {
        let names = try zipEntryNames(first)
        XCTAssertTrue(names.contains("xl/workbook.xml") && names.contains("xl/worksheets/sheet1.xml"), "\(label) \(names)")
        XCTAssertEqual(names, try zipEntryNames(second), "\(label), the entry names")
        for name in names {
            // unzip reads a name as a pattern, so a bracket is matched as itself with `[[]`.
            let pattern = name.replacingOccurrences(of: "[", with: "[[]")
            XCTAssertEqual(try unzip(["-p", first.path, pattern]), try unzip(["-p", second.path, pattern]), "\(label), the entry \(name)")
        }
    }

    private static func zipEntryNames(_ url: URL) throws -> [String] {
        String(decoding: try unzip(["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }

    private static func unzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip \(arguments)")
        return data
    }

    /// A against C on the facts of 1.7, each record path read relative to its side root.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root, parityCase.format)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(".lungfish-export-inputs") && !Self.variesWithTheArchive($0, parityCase)
        }
        XCTAssertEqual(others.map(\.description), [], "\(parityCase) only the record and the inputs folder may differ between A and C")
        try assertSameOutput(runs.a, runs.c, parityCase, "\(parityCase) A against C")

        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        let inputsA = Self.inputs(of: a, under: runs.a.root).filter { !$0.key.contains("/.lungfish-export-inputs/") }
        let allC = Self.inputs(of: c, under: runs.c.root)
        let inputsC = allC.filter { !$0.key.contains("/.lungfish-export-inputs/") }
        XCTAssertEqual(inputsA, inputsC, "\(parityCase) the manifest and the tab's databases with their digests")
        XCTAssertEqual(inputsC.keys.sorted(), Self.expectedInputs(parityCase), "\(parityCase)")
        let selections = allC.keys.filter { $0.contains("/.lungfish-export-inputs/") }
        XCTAssertEqual(selections.map { ($0 as NSString).lastPathComponent }, ["selection.json"], "\(parityCase)")
        XCTAssertTrue(allC.values.allSatisfy { $0 != "no digest" }, "\(parityCase) every input has its digest")

        let masked = parityCase.format == .xlsx ? ["xlsxArchiveArgv"] : []
        let resolvedA = a.options.resolvedDefaults.filter { !(masked + ["replayScope", "replaysUpstreamAnalysis"]).contains($0.key) }
        let resolvedC = c.options.resolvedDefaults.filter { !masked.contains($0.key) }
        XCTAssertEqual(resolvedA, resolvedC, "\(parityCase) every resolved key the leaf writes")
        XCTAssertEqual(a.options.defaults, c.options.defaults, "\(parityCase) defaults")
    }

    /// The prediction rows of the lane report (BIO 7). The identity fields, the old argv's `explicit` keys, the
    /// `/bin/cp` replay's `resolved` keys and the retained inputs go, and the record's argv is the row's command.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        let outputA = Self.outputURL(in: runs.a.root, parityCase.format)
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(Array(a.argv.prefix(10)), [
            "Lungfish.app", "export-annotation-table", "--tab", parityCase.tab.rawValue, "--scope", "allMatching",
            "--format", parityCase.format.rawValue, "--output", outputA.path,
        ])
        XCTAssertEqual(Set(a.argv.dropFirst(10).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)), ["--source"])
        XCTAssertEqual(a.durableReplayArgv?.first, "/bin/cp")
        XCTAssertEqual(a.durableReplayArgv?.last, outputA.path)
        XCTAssertEqual(a.workflowName, "lungfish app annotation table export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys).subtracting(c.options.resolvedDefaults.keys), ["replayScope", "replaysUpstreamAnalysis"])
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["outputFormat", "outputPath", "scope", "sourcePaths", "tab"])
        let retained = Self.inputs(of: a, under: runs.a.root).keys.filter { $0.contains("/.lungfish-export-inputs/") }
        XCTAssertEqual(retained.map { ($0 as NSString).lastPathComponent }.sorted(), ["selected.\(parityCase.format.rawValue)", "selection.json"])

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, AnnotationTableExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["force", "outputFormat", "outputPath", "tab"])
    }

    /// Each input's path below `root`, with its digest.
    static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
