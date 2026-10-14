// ProvenanceStepTerminationDisplayTests.swift - What the Provenance tab shows of a step's observation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.10 lane U37. A classifier step now carries an `observation`, what ToolProcess saw of its launch
/// (lane S36). The Provenance tab shows it as P2 of Phase 2.8 settles it. A line shows only when it adds
/// something, Output reads Not recorded only when a step did not exit 0, and the Environment is one line in the
/// step's disclosure.
///
/// The cases load the hand-written records `Tests/Fixtures/provenance-display/Analyses/observed-*` through the real
/// lookup and compare what the tab shows with `Tests/Fixtures/provenance-display/expected/observed-*.json`. The
/// first commit of the lane pinned these files at the base, where the tab shows nothing of an observation. The
/// commit that adds the lines changes exactly the `observation` objects of the expected files, and no other
/// expected file of the folder.
@MainActor
final class ProvenanceStepTerminationDisplayTests: XCTestCase {

    // MARK: - The observed records

    /// A kraken2 step that exited 0 with its output read whole, in an environment its adapter started empty.
    func testACleanExitShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-clean-exit")

        XCTAssertEqual(try observation(of: model).termination, .exited(code: 0))
        XCTAssertEqual(try observation(of: model).outputComplete, true)
    }

    /// A Bracken step that exited 2 and never said whether its output was read whole.
    func testANonzeroExitShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-nonzero-exit")

        XCTAssertEqual(try observation(of: model).termination, .exited(code: 2))
        XCTAssertNil(try observation(of: model).outputComplete)
    }

    /// A kraken2 step an outside signal killed, which cut its output short.
    func testASignalShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-signal")

        XCTAssertEqual(try observation(of: model).termination, .signaled(signal: 9))
        XCTAssertEqual(try observation(of: model).outputComplete, false)
    }

    /// A Bracken step ToolProcess stopped because the run was cancelled.
    func testACancelShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-cancelled")

        XCTAssertEqual(try observation(of: model).termination, .signaled(signal: 15))
        XCTAssertEqual(try observation(of: model).stop, .cancelled)
        XCTAssertEqual(model.resolvedEnvelope?.status, .cancelled)
    }

    /// A Bracken step whose process could not start.
    func testALaunchFailureShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-launch-failure")

        XCTAssertEqual(
            try observation(of: model).termination,
            .launchFailed(reason: "posix_spawn failed, no such file or directory")
        )
    }

    /// An EsViritu step whose adapter extended the inherited environment, set one variable and removed one.
    func testAnEnvironmentChangeShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-environment-change")

        let environment = try XCTUnwrap(try observation(of: model).environment)
        XCTAssertEqual(environment.base, .inherited)
        XCTAssertEqual(environment.changed, ["ESVIRITU_DB", "PATH"])
        XCTAssertEqual(environment.unset, ["PYTHONHOME"])
    }

    /// A step whose adapter changed nothing in the inherited environment. The observation says so, and the
    /// display is the display of a record with no observation.
    func testAnUnchangedEnvironmentShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-environment-none")

        let environment = try XCTUnwrap(try observation(of: model).environment)
        XCTAssertEqual(environment.base, .inherited)
        XCTAssertTrue(environment.changed.isEmpty && environment.unset.isEmpty && environment.pathPrefix.isEmpty)
    }

    /// The same record as the unchanged environment, written before a step could carry an observation.
    func testAnOlderRecordWithNoObservationShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-older-record")

        XCTAssertNil(model.resolvedEnvelope?.steps.first?.observation)
    }

    // MARK: - The expected files

    /// Every expected display file of the folder is the exact text the snapshot writes for it, so a snapshot
    /// field added for the observation changes no file of a record that has none (QA 1).
    func testEveryExpectedFileIsTheCanonicalTextOfItsSnapshot() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ProvenanceDisplayFixtures.expectedDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 16, "The folder holds the eight legacy files and the eight observed ones: \(names)")
        for name in names {
            let url = ProvenanceDisplayFixtures.expectedDirectory.appendingPathComponent(name)
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            let rewritten = try ProvenanceDisplaySnapshot.decode(expected: Data(contentsOf: url)).canonicalJSON() + "\n"
            XCTAssertEqual(rewritten, onDisk, "\(name) is not the canonical text of its snapshot.")
        }
    }

    // MARK: - Harness

    private func observation(of model: ProvenanceInspectorViewModel) throws -> ProvenanceStepObservation {
        try XCTUnwrap(
            model.resolvedEnvelope?.steps.first?.observation,
            "The record's step carries an observation this build reads."
        )
    }

    /// Copies the committed record of `folder` into a temporary project, loads it through the real lookup and
    /// compares what the tab shows with the expected file of the same name. Returns the loaded model.
    @discardableResult
    private func assertDisplay(
        folder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let project = try makeProject()
        let analysis = project.appendingPathComponent("Analyses/\(folder)", isDirectory: true)
        let sidecar = analysis.appendingPathComponent(".lungfish-provenance.json")
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: ProvenanceDisplayFixtures.directory
                .appendingPathComponent("Analyses/\(folder)/.lungfish-provenance.json"),
            to: sidecar
        )
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: analysis, sidebarType: .analysisResult, contentMode: .genomics, displayName: folder
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)
        XCTAssertNotNil(model.resolvedEnvelope, "No record was found for \(folder).", file: file, line: line)
        XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, ".lungfish-provenance.json", file: file, line: line)

        let snapshot = ProvenanceDisplaySnapshot.capture(
            model, for: ProvenanceDisplayCase(name: folder), redaction: ProvenanceDisplayRedaction(projectURL: project)
        )
        let actual = try snapshot.canonicalJSON()
        XCTAssertEqual(
            try snapshot.privatePathLeaks(), [],
            "The snapshot of \(folder) names a private path, so it cannot be committed.", file: file, line: line
        )
        let expectedURL = ProvenanceDisplayFixtures.expectedDirectory.appendingPathComponent("\(folder).json")
        guard let expectedData = try? Data(contentsOf: expectedURL) else {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: folder)
            XCTFail(
                "No expected display at \(expectedURL.path). The display now is in \(written?.path ?? "(not written)").",
                file: file, line: line
            )
            return model
        }
        let expected = try ProvenanceDisplaySnapshot.decode(expected: expectedData)
        if snapshot != expected {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: folder)
            XCTFail(
                """
                The Provenance tab no longer shows \(folder) as it did.
                Compare \(expectedURL.path)
                with    \(written?.path ?? "(not written)")
                \(ProvenanceDisplaySnapshot.lineDifferences(expected: try expected.canonicalJSON(), actual: actual))
                """,
                file: file, line: line
            )
        }
        return model
    }

    /// A fresh `.lungfish` project, named with a space as the other display suites name theirs.
    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-step-termination")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Observed Records.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }
}
