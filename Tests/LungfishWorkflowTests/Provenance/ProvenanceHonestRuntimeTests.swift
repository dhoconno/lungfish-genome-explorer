// ProvenanceHonestRuntimeTests.swift - A runtime fact a record never held reads as not recorded
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// A fact a record never held is nil, never a value from the reading Mac and never a sentinel
/// (plan decision S4). The readers once filled the app version, executable path, process ID,
/// operating system, architecture, dependency set and workflow version from the process that read
/// the record. Writers still record their own process, so a written record is unchanged.
final class ProvenanceHonestRuntimeTests: XCTestCase {

    // MARK: Every reader, every corpus case

    /// Each runtime fact and the workflow version that the tolerant reader or the finder shows is a
    /// value the record's own path-resolved bytes hold, or nil.
    func testNoReaderShowsARuntimeFactTheRecordNeverHeld() throws {
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let held = try Self.heldValues(of: materialized.sidecar)

            var readings: [(reader: String, envelope: ProvenanceEnvelope)] = [
                ("tolerant reader", try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))),
            ]
            if let selection = materialized.selection,
               let found = ProvenanceRecorder.findProvenanceEnvelope(for: selection) {
                readings.append(("finder", found.envelope))
            }
            for (reader, envelope) in readings {
                for (fact, value) in Self.runtimeFacts(of: envelope) {
                    guard let value else { continue }
                    XCTAssertTrue(
                        held.contains(value),
                        "the \(reader) shows \(fact) \(value) for \(item.id), which the record does not hold"
                    )
                }
            }
        }
    }

    // MARK: Each shape

    /// An envelope that a script wrote holds an executable path, a process ID and an operating
    /// system, and no app version, architecture, dependency set or workflow version.
    func testAnEnvelopeReadsTheRuntimeKeysItLacksAsNotRecorded() throws {
        let envelope = try load("s2-analysis-kraken2-fixture")
        XCTAssertNil(envelope.runtimeIdentity.appVersion)
        XCTAssertNil(envelope.runtimeIdentity.architecture)
        XCTAssertNil(envelope.runtimeIdentity.dependencySet)
        XCTAssertNil(envelope.workflowVersion)
        XCTAssertEqual(envelope.runtimeIdentity.executablePath, "python3")
        XCTAssertEqual(Self.text(envelope.runtimeIdentity.processIdentifier), "38076")
        XCTAssertEqual(envelope.runtimeIdentity.operatingSystemVersion, "macOS-26.4.1-arm64-arm-64bit")
    }

    /// A bare run records only an app version and an operating system.
    func testABareRunReadsOnlyTheAppVersionAndSystemItRecorded() throws {
        let envelope = try load("s3-write-sidecar-bare-run")
        XCTAssertNil(envelope.runtimeIdentity.executablePath)
        XCTAssertNil(envelope.runtimeIdentity.processIdentifier)
        XCTAssertNil(envelope.runtimeIdentity.architecture)
        XCTAssertNil(envelope.runtimeIdentity.dependencySet)
        XCTAssertEqual(envelope.runtimeIdentity.appVersion, "Lungfish 2026.10.10 (dev)")
        XCTAssertEqual(envelope.runtimeIdentity.operatingSystemVersion, "macOS 26.7.1 (arm64)")
        XCTAssertEqual(envelope.workflowVersion, "Lungfish 2026.10.10 (dev)")
    }

    /// The shipped reference bundle's primitive record names its executable and conda prefix only.
    func testAPrimitiveRecordReadsOnlyTheRuntimeFactsItHolds() throws {
        let envelope = try load("s4-mcm-mhcref-shipped")
        XCTAssertEqual(envelope.runtimeIdentity.executablePath, "python3")
        XCTAssertNil(envelope.runtimeIdentity.appVersion)
        XCTAssertNil(envelope.runtimeIdentity.processIdentifier)
        XCTAssertNil(envelope.runtimeIdentity.operatingSystemVersion)
        XCTAssertNil(envelope.runtimeIdentity.architecture)
        XCTAssertNil(envelope.runtimeIdentity.dependencySet)
        XCTAssertNil(envelope.workflowVersion)
    }

    /// `WorkflowRun` needs text, so the legacy view of a record that holds no app version or
    /// operating system shows the empty string, never the reading Mac's.
    func testTheLegacyRunViewShowsEmptyTextForFactsTheRecordNeverHeld() throws {
        let run = try load("s4-mcm-mhcref-shipped").legacyWorkflowRun()
        XCTAssertEqual(run.appVersion, "")
        XCTAssertEqual(run.hostOS, "")
        XCTAssertEqual(run.runtime.appVersion, "")
        XCTAssertEqual(run.runtime.hostOS, "")
    }

    // MARK: Writers

    /// A writer records its own process, so the memberwise defaults fill every field as before,
    /// and a present value encodes exactly as before.
    func testAWriterStillRecordsItsOwnProcess() throws {
        let identity = ProvenanceRuntimeIdentity()
        XCTAssertEqual(identity.appVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(identity.executablePath, ProvenanceRuntimeIdentity.currentExecutablePath)
        XCTAssertEqual(Self.text(identity.processIdentifier), "\(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertEqual(identity.operatingSystemVersion, WorkflowRun.currentHostOS)
        XCTAssertEqual(identity.architecture, ProvenanceRuntimeIdentity.currentArchitecture)

        let written = ProvenanceRuntimeIdentity(
            appVersion: "Lungfish 2026.10.10 (fixture)",
            executablePath: "/usr/local/bin/lungfish-cli",
            processIdentifier: 12345,
            operatingSystemVersion: "macOS 26.0.0 (arm64)",
            architecture: "arm64",
            user: nil,
            condaEnvironment: "lungfish",
            dependencySet: "2026.2"
        )
        XCTAssertEqual(
            String(decoding: try ProvenanceJSON.encoder.encode(written), as: UTF8.self),
            """
            {
              "appVersion" : "Lungfish 2026.10.10 (fixture)",
              "architecture" : "arm64",
              "condaEnvironment" : "lungfish",
              "dependencySet" : "2026.2",
              "executablePath" : "\\/usr\\/local\\/bin\\/lungfish-cli",
              "operatingSystemVersion" : "macOS 26.0.0 (arm64)",
              "processIdentifier" : 12345
            }
            """
        )
    }

    // MARK: Helpers

    private func load(_ caseID: String) throws -> ProvenanceEnvelope {
        let materialized = try ProvenanceCompatCorpus.materialize(caseID)
        defer { materialized.cleanup() }
        return try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
    }

    /// The facts a reader once filled from its own process, as text, or nil when absent.
    static func runtimeFacts(of envelope: ProvenanceEnvelope) -> [(String, String?)] {
        let runtime = envelope.runtimeIdentity
        return [
            ("appVersion", text(runtime.appVersion)),
            ("executablePath", text(runtime.executablePath)),
            ("processIdentifier", text(runtime.processIdentifier)),
            ("operatingSystemVersion", text(runtime.operatingSystemVersion)),
            ("architecture", text(runtime.architecture)),
            ("dependencySet", text(runtime.dependencySet)),
            ("workflowVersion", text(envelope.workflowVersion)),
        ]
    }

    /// A value as text, or nil when it is absent.
    static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        return "\(value)"
    }

    /// Every string and number in the record after its project paths resolve, as text.
    static func heldValues(of sidecar: URL) throws -> Set<String> {
        let resolved = PortablePath.resolveJSON(
            try Data(contentsOf: sidecar),
            forFileAt: sidecar,
            encoder: ProvenanceJSON.encoder
        )
        var values = Set<String>()
        func collect(_ value: Any) {
            switch value {
            case let dictionary as [String: Any]:
                dictionary.values.forEach(collect)
            case let array as [Any]:
                array.forEach(collect)
            case let text as String:
                values.insert(text)
                values.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case let number as NSNumber:
                values.insert(number.stringValue)
            default:
                break
            }
        }
        collect(try JSONSerialization.jsonObject(with: resolved))
        return values
    }
}
