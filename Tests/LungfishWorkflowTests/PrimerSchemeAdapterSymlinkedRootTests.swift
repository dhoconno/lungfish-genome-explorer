// PrimerSchemeAdapterSymlinkedRootTests.swift - A primer-scheme design under a symlinked folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 c3, grant (b). The adapter records `run.py` through `Path(__file__).resolve()` (run.py:203),
// which keeps `/private`, and the request path as LGE passed it. A project reached through a symlink (a linked folder,
// or `/var` and `/tmp` for `/private/var` and `/private/tmp`) gave two spellings of one file, and the result loader
// refused the finished run with "Adapter provenance command differs from the launched argv".

import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerSchemeAdapterSymlinkedRootTests: XCTestCase {
    /// A design whose project is spelled through a symlink passes the launched-argv check. At the base it failed there
    /// with the check's message. The design now saves at the physical path too (lane 13.49 resolves the destination
    /// parent once in the pipeline), which `PrimerDesignSpelledDestinationTests` asserts, so this test asserts the
    /// check only.
    func testADesignUnderASymlinkedRootPassesTheLaunchedArgvCheck() async throws {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        let (input, request) = try Self.linkedRequest(fixture)
        XCTAssertNotEqual(input.path, Self.physicalPath(input.path), "the input is reached through a symlink")
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(
                command: Self.recording(command, runPy: Self.physicalPath(command.arguments[0])), mode: .tiled)
            return fixture.execution(for: command)
        }
        do {
            _ = try await pipeline.run(request: request)
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            XCTAssertFalse(text.contains("Adapter provenance command differs from the launched argv"), text)
        }
    }

    /// The negative control. A recorded argv that names another request file is still refused.
    func testARecordedArgvNamingAnotherRequestIsStillRefused() async throws {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        let (_, request) = try Self.linkedRequest(fixture)
        let pipeline = fixture.pipeline { command in
            var recorded = Self.recording(command, runPy: Self.physicalPath(command.arguments[0]))
            recorded = Self.recording(recorded, request: fixture.inputURL.path)
            try fixture.writeAdapterSuccess(command: recorded, mode: .tiled)
            return fixture.execution(for: command)
        }
        do {
            _ = try await pipeline.run(request: request)
            XCTFail("a recorded argv naming another request must be refused")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            XCTAssertTrue(text.contains("Adapter provenance command differs from the launched argv"), text)
        }
    }

    /// The comparison alone (ruling 4b of the 12.16 review). `/private/var` and `/var` name one file, a different folder
    /// with the same last component does not, and a non-path word compares as written.
    func testTheLaunchedArgvComparisonResolvesOnlyAbsolutePaths() {
        let python = "/var/x/env/bin/python"
        let launched = [python, "/var/x/adapter/run.py", "--request", "/var/x/request.json"]
        func matches(_ argv: [String], executable: String = python) -> Bool {
            PrimerSchemeAdapterResultLoader.recordedCommandMatchesLaunch(
                argv: argv, executable: executable, launched: launched)
        }
        XCTAssertTrue(matches(launched))
        XCTAssertTrue(matches([python, "/private/var/x/adapter/run.py", "--request", "/var/x/request.json"]))
        XCTAssertTrue(matches(launched, executable: "/private/var/x/env/bin/python"))
        XCTAssertFalse(matches([python, "/private/var/y/adapter/run.py", "--request", "/var/x/request.json"]))
        XCTAssertFalse(matches([python, "/var/x/adapter/run.py", "--requests", "/var/x/request.json"]))
        XCTAssertFalse(matches([python, "x/adapter/run.py", "--request", "/var/x/request.json"]))
        XCTAssertFalse(matches(Array(launched.dropLast())))
        XCTAssertFalse(matches(launched, executable: "/private/var/y/env/bin/python"))
        XCTAssertFalse(PrimerSchemeAdapterResultLoader.recordedCommandMatchesLaunch(
            argv: [], executable: python, launched: []))
    }

    // MARK: - Helpers

    /// The fixture's tiled request with its input and its `Analyses` folder in a project spelled through `/var`, the
    /// symlink macOS keeps for `/private/var`, as a project under `/tmp`, `/var` or a linked folder is spelled. The
    /// destination's parent is a real folder.
    private static func linkedRequest(
        _ fixture: PrimerSchemePipelineFixture
    ) throws -> (URL, PrimerSchemeDesignRequest) {
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture.inputURL, to: project.appendingPathComponent(fixture.inputURL.lastPathComponent))
        XCTAssertTrue(project.path.hasPrefix("/private/var/"), "the fixture root is the physical temp folder")
        let link = URL(fileURLWithPath: String(project.path.dropFirst("/private".count)), isDirectory: true)
        let input = link.appendingPathComponent(fixture.inputURL.lastPathComponent)
        let destination = link.appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(fixture.destination.lastPathComponent)
        let options = fixture.tiledOptions
        let request = PrimerSchemeDesignRequest(
            analysisID: fixture.analysisID, runID: fixture.runID, resultID: fixture.resultID,
            inputURLs: [input], destinationURL: destination,
            options: options,
            invocation: .init(
                argv: ["lungfish", "primer", "design", options.engine.rawValue],
                callerVersion: "test", explicitOptions: options.provenanceOptions,
                runtimeIdentity: fixture.runtime),
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)],
            executableURL: fixture.executableURL,
            inputIDs: [input: fixture.inputID])
        return (input, request)
    }

    /// The command as the adapter records it, with `run.py` or the request path spelled another way.
    private static func recording(
        _ command: PrimerSchemeAdapterCommand, runPy: String? = nil, request: String? = nil
    ) -> PrimerSchemeAdapterCommand {
        var arguments = command.arguments
        if let runPy { arguments[0] = runPy }
        if let request { arguments[2] = request }
        return PrimerSchemeAdapterCommand(
            executableURL: command.executableURL, arguments: arguments, request: command.request,
            requestURL: command.requestURL, adapterDirectoryURL: command.adapterDirectoryURL,
            outputDirectoryURL: command.outputDirectoryURL, workingDirectoryURL: command.workingDirectoryURL,
            environment: command.environment)
    }

    /// The path `realpath(3)` gives, as Python's `Path.resolve()` does, which keeps `/private`.
    private static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
