// ToolVersionEvidenceCondaMetaTests.swift - Version evidence read from the environment that ran a managed tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5, decision P12. A managed tool's version is read from the conda-meta of the environment
// that ran it, as an observed version whose reported line is the package record, and the lock's pin stands in
// only when the environment holds no usable record. The reads here are pure file reads on fake environments.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ToolVersionEvidenceCondaMetaTests: XCTestCase {
    private var root: URL!
    private let minimap2 = ManagedToolID(rawValue: "minimap2")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolVersionEvidenceCondaMetaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func environment(_ name: String) -> URL {
        root.appendingPathComponent("envs/\(name)", isDirectory: true)
    }

    private func lockPin(of id: ManagedToolID) throws -> String {
        try XCTUnwrap(ManagedToolLock.bundled.entry(id: id)?.version, id.rawValue)
    }

    /// A lock of one tool, `demo-tool`, installed by the package `demo-package` in `demo-env`.
    private var demoLock: ManagedToolLock {
        ManagedToolLock(
            packID: "test", displayName: "Test", version: "1",
            tools: [ManagedToolLock.ToolSpec(
                id: "demo-tool", environment: "demo-env", packageSpec: "bioconda::demo-package=1.0=h0_0",
                executables: ["demo"], version: "1.0")],
            managedData: [], packTools: [], pipelines: [])
    }

    // MARK: - The environment that ran

    func testTheEnvironmentsVersionIsRecordedWhenItDiffersFromTheLock() throws {
        let environment = environment("minimap2")
        try CondaMetaRecordWriter.write(environment: environment, package: "minimap2", version: "9.9.9", build: "h0abc_0")

        let evidence = ToolVersionEvidence.condaMeta(id: minimap2, environment: environment)

        XCTAssertEqual(evidence, .observed(version: "9.9.9", reportedLine: "minimap2-9.9.9-h0abc_0"))
        XCTAssertEqual(evidence.recordedString, "9.9.9")
        XCTAssertNotEqual(evidence.version, try lockPin(of: minimap2), "the environment differs from the lock")
        XCTAssertEqual(ToolVersionEvidence.lockPin(for: minimap2), .lockPin(version: try lockPin(of: minimap2), id: minimap2))
    }

    /// An environment that equals the lock is still observed. The record was read, and that is what makes it
    /// a measurement and not a pin.
    func testAnEnvironmentThatEqualsTheLockIsObservedNotPinned() throws {
        let lock = ManagedToolLock.bundled
        let entry = try XCTUnwrap(lock.entry(id: minimap2))
        let spec = try XCTUnwrap(CondaSpec(spec: try XCTUnwrap(lock.packageSpec(of: entry))))
        let environment = environment("minimap2")
        try CondaMetaRecordWriter.write(
            environment: environment, package: spec.name, version: spec.version, build: spec.build)

        let evidence = ToolVersionEvidence.condaMeta(id: minimap2, environment: environment)

        XCTAssertEqual(evidence, .observed(version: spec.version, reportedLine: "\(spec.name)-\(spec.version)-\(spec.build ?? "")"))
        XCTAssertNotEqual(evidence, .lockPin(for: minimap2))
    }

    func testTheReportedLineHoldsNoHostPath() throws {
        let environment = environment("minimap2")
        let file = try CondaMetaRecordWriter.write(
            environment: environment, package: "minimap2", version: "2.30", build: "h0abc_0")
        let record = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(record.contains(root.path), "the fake record keeps host paths, as a real one does")

        let evidence = ToolVersionEvidence.condaMeta(id: minimap2, environment: environment)

        guard case .observed(_, let reportedLine?) = evidence else { return XCTFail("\(evidence)") }
        XCTAssertFalse(reportedLine.contains("/"), reportedLine)
        XCTAssertFalse(reportedLine.contains(root.path), reportedLine)
        let encoded = try String(data: JSONEncoder().encode(evidence), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(root.path), encoded)
        XCTAssertFalse(encoded.contains("/Users"), encoded)
    }

    func testAPartThatIsNotAPlainTokenIsNotUsed() throws {
        let environment = environment("minimap2")
        try CondaMetaRecordWriter.write(
            environment: environment, package: "minimap2", version: "2.30/../../x", build: "h0abc_0")

        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: minimap2, environment: environment),
            .lockPin(for: minimap2), "a version with a slash could carry a path, so the lock's pin stands in")

        let spaced = self.environment("spaced")
        try CondaMetaRecordWriter.write(environment: spaced, package: "minimap2", version: "2.30", build: "h0 abc\n_0")
        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: spaced), .lockPin(for: minimap2))

        let empty = self.environment("empty-version")
        try CondaMetaRecordWriter.write(environment: empty, package: "minimap2", version: "", build: "h0abc_0")
        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: empty), .lockPin(for: minimap2))
    }

    func testARecordWithoutABuildIsStillObserved() throws {
        let environment = environment("minimap2")
        try CondaMetaRecordWriter.write(environment: environment, package: "minimap2", version: "2.30", build: nil)

        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: minimap2, environment: environment),
            .observed(version: "2.30", reportedLine: "minimap2-2.30"))
    }

    // MARK: - The lock's pin

    func testAnEnvironmentWithNoUsableRecordRecordsTheLockPin() throws {
        let pin = ToolVersionEvidence.lockPin(for: minimap2)
        XCTAssertEqual(pin, .lockPin(version: try lockPin(of: minimap2), id: minimap2))

        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: environment("missing")), pin)

        let noMeta = environment("no-meta")
        try FileManager.default.createDirectory(at: noMeta, withIntermediateDirectories: true)
        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: noMeta), pin)

        let other = environment("other-package")
        try CondaMetaRecordWriter.write(environment: other, package: "samtools", version: "1.99", build: "h0_0")
        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: other), pin)

        let unreadable = environment("unreadable")
        try FileManager.default.createDirectory(
            at: unreadable.appendingPathComponent("conda-meta"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: unreadable.appendingPathComponent("conda-meta/minimap2-2.30-h0_0.json"))
        XCTAssertEqual(ToolVersionEvidence.condaMeta(id: minimap2, environment: unreadable), pin)
    }

    // MARK: - Which package

    func testThePackageIsTheOneTheLockSpecInstalls() throws {
        let environment = environment("demo-env")
        try CondaMetaRecordWriter.write(environment: environment, package: "demo-package", version: "1.1", build: "h1_0")
        try CondaMetaRecordWriter.write(environment: environment, package: "demo-tool", version: "5.0", build: "h2_0")

        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "demo-tool"), environment: environment, lock: demoLock),
            .observed(version: "1.1", reportedLine: "demo-package-1.1-h1_0"))
    }

    /// The bundled lock names the BBTools package `bbmap`, so the record of `bbmap` is read for `bbtools`.
    func testTheBBToolsEntryReadsTheBBMapPackage() throws {
        let environment = environment("bbtools")
        try CondaMetaRecordWriter.write(environment: environment, package: "bbmap", version: "40.99", build: "h0_0")

        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "bbtools"), environment: environment),
            .observed(version: "40.99", reportedLine: "bbmap-40.99-h0_0"))
    }

    func testARecordOfADifferentPackageWithTheSameStartIsNotRead() throws {
        let pysam = ManagedToolID(rawValue: "pysam")
        let environment = environment("pysam")
        try CondaMetaRecordWriter.write(environment: environment, package: "pysam-stubs", version: "1.0", build: "h0_0")
        try CondaMetaRecordWriter.write(environment: environment, package: "pysam", version: "0.99.0", build: "py310h0_1")

        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: pysam, environment: environment),
            .observed(version: "0.99.0", reportedLine: "pysam-0.99.0-py310h0_1"))
    }

    // MARK: - What a conda record cannot say

    func testAnIdTheLockDoesNotHoldIsUnknown() {
        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "no-such-tool"), environment: environment("x")),
            .unknown(.noProbe))
    }

    /// Bracken keeps an existing install and overlays a source build, and primalscheme3 is a wheel in a Python
    /// runtime. A conda record or the lock's pin could name a version that is not the one that ran (risk K4).
    func testASourceBuiltOrPythonRuntimeToolIsUnknown() throws {
        let bracken = environment("bracken")
        try CondaMetaRecordWriter.write(environment: bracken, package: "bracken", version: "1.0.0", build: "1")
        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "bracken"), environment: bracken), .unknown(.noProbe))

        let primalscheme3 = environment("primalscheme3")
        try CondaMetaRecordWriter.write(environment: primalscheme3, package: "python", version: "3.12.11", build: "hc22306f_0_cpython")
        XCTAssertEqual(
            ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "primalscheme3"), environment: primalscheme3),
            .unknown(.noProbe))
    }

    // MARK: - Wire shape

    func testTheObservedEvidenceKeepsItsReportedLineOnTheWire() throws {
        let environment = environment("minimap2")
        try CondaMetaRecordWriter.write(environment: environment, package: "minimap2", version: "2.30", build: "h0abc_0")
        let evidence = ToolVersionEvidence.condaMeta(id: minimap2, environment: environment)

        let data = try JSONEncoder().encode(evidence)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["source": "observed", "version": "2.30", "reportedLine": "minimap2-2.30-h0abc_0"])
        XCTAssertEqual(try JSONDecoder().decode(ToolVersionEvidence.self, from: data), evidence)
    }
}
