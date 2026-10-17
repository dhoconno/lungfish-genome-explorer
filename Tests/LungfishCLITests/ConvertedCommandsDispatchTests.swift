// ConvertedCommandsDispatchTests.swift - ArgumentParser reaches the cancel scope of the 13 no-tool commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S61 (K7), review S61 Fix 1. The ten `msa` actions and the three tree transforms get
// their SIGTERM scope from a protocol extension (`MSAActionCommand.run()` and `TreeTransformCommand.run()`),
// while each struct also declared its own synchronous `run()`. A type's own member outranks a protocol
// extension default as the witness of `AsyncParsableCommand.run()`, and ArgumentParser calls `run()`
// through that witness. So the built command could still run its old body and never reach the cancel path,
// and the in-process pins, which call the cancel path by name, cannot see that. This test runs each command
// the way ArgumentParser does and asks whether the run entered a SIGTERM scope, through the debug seam
// `SIGTERMEndTrace.action`, which `SIGTERMCancellation.end()` calls at the end of every scope. Every path
// below is absent, so each run fails at validation and writes nothing.

import ArgumentParser
import Foundation
import Synchronization
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

#if DEBUG
/// Counts what `SIGTERMCancellation.end()` reports. A class, since a `Mutex` cannot be captured by an
/// escaping closure.
private final class EndCount: Sendable {
    private let storage = Mutex(0)
    func note() { storage.withLock { $0 += 1 } }
    var count: Int { storage.withLock { $0 } }
}

/// Parses `arguments` as `type`, runs it the way ArgumentParser's `main()` does, and says whether the run
/// entered a SIGTERM scope.
private func enteredCancelScope(_ arguments: [String], _ type: any ParsableCommand.Type) async throws -> Bool {
    var command = try type.parse(arguments)
    let ends = EndCount()
    await SIGTERMEndTrace.$action.withValue({ _ in ends.note() }) {
        if var asyncCommand = command as? any AsyncParsableCommand {
            _ = try? await asyncCommand.run()
        } else {
            _ = try? command.run()
        }
    }
    return ends.count > 0
}

final class ConvertedCommandsDispatchTests: XCTestCase {
    private struct Row {
        let name: String
        let type: any ParsableCommand.Type
        let arguments: [String]
    }

    /// One row per command, with its required arguments. Every path sits under `root` and does not exist.
    private func rows(under root: URL) -> [Row] {
        let msaBundle = root.appendingPathComponent("absent.lungfishmsa").path
        let treeBundle = root.appendingPathComponent("absent.lungfishtree").path
        func output(_ name: String) -> String { root.appendingPathComponent(name).path }
        return [
            Row(
                name: "MSACommand.AddSubcommand", type: MSACommand.AddSubcommand.self,
                arguments: [msaBundle, "--row", "r1", "--columns", "1-2", "--name", "gene1", "--type", "gene"]
            ),
            Row(
                name: "MSACommand.EditSubcommand", type: MSACommand.EditSubcommand.self,
                arguments: [msaBundle, "--annotation", "a1"]
            ),
            Row(
                name: "MSACommand.DeleteSubcommand", type: MSACommand.DeleteSubcommand.self,
                arguments: [msaBundle, "--annotation", "a1"]
            ),
            Row(
                name: "MSACommand.ProjectSubcommand", type: MSACommand.ProjectSubcommand.self,
                arguments: [msaBundle, "--source-annotation", "a1", "--target-rows", "all"]
            ),
            Row(
                name: "MSACommand.ExportSubcommand", type: MSACommand.ExportSubcommand.self,
                arguments: [msaBundle, "--output", output("export.fasta")]
            ),
            Row(
                name: "MSACommand.ConsensusSubcommand", type: MSACommand.ConsensusSubcommand.self,
                arguments: [msaBundle, "--output", output("consensus.fasta")]
            ),
            Row(
                name: "MSACommand.ExtractSubcommand", type: MSACommand.ExtractSubcommand.self,
                arguments: [msaBundle, "--output", output("extract.fasta")]
            ),
            Row(
                name: "MSACommand.MaskColumnsSubcommand", type: MSACommand.MaskColumnsSubcommand.self,
                arguments: [msaBundle, "--ranges", "1-2", "--output", output("masked.lungfishmsa")]
            ),
            Row(
                name: "MSACommand.TrimColumnsSubcommand", type: MSACommand.TrimColumnsSubcommand.self,
                arguments: [msaBundle, "--gap-only", "--output", output("trimmed.lungfishmsa")]
            ),
            Row(
                name: "MSACommand.DistanceSubcommand", type: MSACommand.DistanceSubcommand.self,
                arguments: [msaBundle, "--output", output("distance.tsv")]
            ),
            Row(
                name: "TreeCommand.RerootSubcommand", type: TreeCommand.RerootSubcommand.self,
                arguments: ["--bundle", treeBundle, "--on", "t1", "--output", output("rerooted.lungfishtree")]
            ),
            Row(
                name: "TreeCommand.ExtractSubtreeSubcommand", type: TreeCommand.ExtractSubtreeSubcommand.self,
                arguments: ["--bundle", treeBundle, "--node", "n1", "--output", output("subtree.lungfishtree")]
            ),
            Row(
                name: "TreeCommand.RelabelSubcommand", type: TreeCommand.RelabelSubcommand.self,
                arguments: ["--bundle", treeBundle, "--column", "name", "--output", output("relabeled.lungfishtree")]
            ),
        ]
    }

    func testArgumentParserRunEntersTheCancelScopeForEveryNoToolCommand() async throws {
        let root = try TestTempDirectory.make(prefix: "converted-commands-dispatch")
        defer { TestTempDirectory.cleanup(root) }
        let table = rows(under: root)
        XCTAssertEqual(table.count, 13, "ten msa actions and three tree transforms")
        for row in table {
            do {
                let entered = try await enteredCancelScope(row.arguments, row.type)
                print("DISPATCH \(row.name) entered=\(entered)")
                XCTAssertTrue(entered, "\(row.name): run() reached runCancellingOnSIGTERM")
            } catch {
                XCTFail("\(row.name): the arguments did not parse: \(error)")
            }
        }
    }

}
#endif
