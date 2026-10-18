// PrimerDesignCLIGUIParityReplayTests+SchemeEngines.swift - The Olivar and varVAMP designs in the app against the command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M2 (1), PLAN row 12.16 (A67-ENGINES), item 2 of row A67-next of the A67 review, C4 of 2.10 and
// 2.9 O5. A case of an engine the primer scheme adapter runs (`olivar` or `varvamp`) runs the class's three sides on the
// PrimalScheme3 case's alignment and the real engine of the managed environment.
//
// - Side A is the app's route, the class's `sideA` with the engine named, which runs the dialog's command through
//   `CLIPrimerDesignRunner` on the staged CLI (lane 12.17 M2). That is varVAMP only, since Olivar stays in process until
//   its replay (2.13 row A67-OLIVAR). Side A ran the pipeline in process when lane 12.16 proved A against C.
// - Side C is the row with the command built from the same dialog and the built `lungfish-cli` on its arguments, run
//   from an app layout staged beside the case (`stagedCLI`), where the CLI finds the bundled adapter.
// - Side C' is the harness's replay of that command.
//
// A against C and C against C' declare nothing (C4), under OutputEquivalence.MaskPolicy.primerAnalysis. The dialog
// marks every option it sends as supplied, and a command marks only the flags it names, so the two sides' `supplied`
// blocks differ where no flag names a value (Provenance residue of the A67 report, ruling 1 of its review). The policy
// does not compare the explicit options that hold them, so `assertSuppliedResidue` pins that residue by name.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

extension PrimerDesignCLIGUIParityReplayTests {
    /// The three sides of an Olivar or varVAMP case on the alignment fixture and the real engine `tool` of the managed
    /// environment, the recorded argv of side C and C', and the `supplied` residue of side A against side C.
    func assertPrimerSchemeParity(
        _ parityCase: Case, engine: PrimerDesignEngine, tool: String, residue: [String: Set<String>]
    ) async throws {
        let conda = CondaManager.shared
        do {
            _ = try await conda.toolPath(name: tool, environment: tool)
        } catch {
            try ToolAvailability.skipOrFail("\(tool) is not installed in the managed environment: \(error)")
        }
        // The case folder has no symlink in its path. The temp folder is `/var/folders`, which the dialog spells
        // without `/private`, and the bundle writer refuses a destination parent reached through a symlink
        // (`PrimerAnalysisBundleWriter.openSafeExistingDirectory`), so a scheme design there cannot save today. Its
        // name holds no dashed UUID, since the staged CLI's path, which the CLI's envelope records, lies in it and
        // outside the sides' roots, where a UUID would take a number on side C alone.
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let physical = caches.appendingPathComponent("lungfish-primer-parity-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: physical) }
        let environment = ["LUNGFISH_CONDA_ROOT": conda.rootPrefix.path]
        let cli = try stagedCLI(in: physical)
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .primerAnalysis, replayTimeout: .seconds(600),
            environment: { _ in environment }
        )
        let result = try await harness.assertParity(
            parityCase,
            declared: Self.declared,
            in: physical.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try Self.writeAlignmentFixture(root) },
            sideA: { root in
                await self.sideA(root, engine: engine, input: Self.alignmentName, cli: cli, environment: environment)
            },
            sideC: { root in await self.sideC(root, harness: harness, engine: engine, input: Self.alignmentName) }
        )
        let command = try XCTUnwrap(result.runs.c.outcome.recordedCommand, "side C records the row's command")
        XCTAssertTrue(command.hasPrefix("lungfish-cli primers design \(tool) "), command)
        try Self.assertRecordedArgv(of: result.runs.c, is: RecordedCLICommand.arguments(of: command), cli: cli)
        try Self.assertRecordedArgv(
            of: result.runs.cPrime, is: try XCTUnwrap(result.runs.cPrime.replayedArguments.first), cli: cli
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        try Self.assertSuppliedResidue(a: result.runs.a, c: result.runs.c, residue: residue)
        try Self.assertSuppliedResidue(a: result.runs.c, c: result.runs.cPrime, residue: residue.mapValues { _ in [] })
    }

    /// The built CLI in an app layout in `folder`, as the shipped app holds it (ruling 4a of the 12.16 review). A CLI
    /// outside an app finds no bundled resource (`RuntimeResourceLocator`, two security pins), so the Olivar and
    /// varVAMP adapter is out of its reach. The CLI goes to `Stage.app/Contents/MacOS/lungfish-cli` and every `*.bundle`
    /// beside it to `Stage.app/Contents/Resources`, each a copy (an APFS clone) and never a symlink, since the locator
    /// refuses a root whose canonical path leaves `Contents/Resources`. A CLI inside an app takes the app's identity
    /// (`RuntimeAppIdentityResolver`), so the stage's `Info.plist` names the Stable identity, which the built CLI
    /// outside an app resolves too, with no stamped version.
    func stagedCLI(in folder: URL) throws -> URL {
        let manager = FileManager.default
        let built = self.cli.resolvingSymlinksInPath()
        let contents = folder.appendingPathComponent("Stage.app/Contents", isDirectory: true)
        let staged = contents.appendingPathComponent("MacOS/lungfish-cli")
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try manager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let stable = LungfishAppIdentity.stable
        let info: [String: Any] = [
            "CFBundleDisplayName": stable.fullName, "CFBundleName": stable.shortName,
            "CFBundleIdentifier": stable.bundleIdentifier, "CFBundleExecutable": "Lungfish",
            "CFBundlePackageType": "APPL", "LungfishReleaseChannel": stable.releaseChannel.rawValue,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try manager.copyItem(at: built, to: staged)
        let products = built.deletingLastPathComponent()
        for name in try manager.contentsOfDirectory(atPath: products.path).sorted() where name.hasSuffix(".bundle") {
            try manager.copyItem(at: products.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        return staged
    }

    /// In each section of `residue`, the names side A's explicit options (`options.explicit.<section>` of
    /// `provenance/wrapper.json`) mark as supplied are side C's and the section's residue, both sides give the names
    /// they share the same value, and the resolved values are equal. Each block is a `ParameterValue` dictionary.
    static func assertSuppliedResidue(
        a: RouteParitySideRun, c: RouteParitySideRun, residue: [String: Set<String>],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        func entries(_ value: Any?) -> [String: Any]? {
            guard let object = value as? [String: Any] else { return nil }
            return object["type"] as? String == "dictionary" ? object["value"] as? [String: Any] : object
        }
        func explicitOptions(_ run: RouteParitySideRun) throws -> [String: Any] {
            let wrapper = bundleURL(in: run.root).appendingPathComponent("provenance/wrapper.json")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: wrapper)) as? [String: Any], file: file, line: line
            )
            return try XCTUnwrap(
                entries(entries(json["options"])?["explicit"]),
                "side \(run.side) records its explicit options: \(json.keys.sorted())", file: file, line: line
            )
        }
        let optionsA = try explicitOptions(a), optionsC = try explicitOptions(c)
        for (section, names) in residue.sorted(by: { $0.key < $1.key }) {
            let blockA = try XCTUnwrap(entries(optionsA[section]), "side \(a.side) \(section)", file: file, line: line)
            let blockC = try XCTUnwrap(entries(optionsC[section]), "side \(c.side) \(section)", file: file, line: line)
            let suppliedA = try XCTUnwrap(entries(blockA["supplied"]), "\(section) supplied", file: file, line: line)
            let suppliedC = try XCTUnwrap(entries(blockC["supplied"]), "\(section) supplied", file: file, line: line)
            XCTAssertEqual(
                Set(suppliedA.keys).subtracting(suppliedC.keys), names,
                "\(section): side \(a.side) supplies \(suppliedA.keys.sorted()), side \(c.side) \(suppliedC.keys.sorted())",
                file: file, line: line
            )
            XCTAssertEqual(Set(suppliedC.keys).subtracting(suppliedA.keys), [], "\(section)", file: file, line: line)
            for key in Set(suppliedA.keys).intersection(suppliedC.keys) {
                XCTAssertEqual(suppliedA[key] as? NSObject, suppliedC[key] as? NSObject, "\(section).\(key)", file: file, line: line)
            }
            let resolvedA = try XCTUnwrap(entries(blockA["resolved"]), "\(section) resolved", file: file, line: line)
            let resolvedC = try XCTUnwrap(entries(blockC["resolved"]), "\(section) resolved", file: file, line: line)
            XCTAssertEqual(resolvedA as NSDictionary, resolvedC as NSDictionary, "\(section) resolved", file: file, line: line)
        }
    }
}
