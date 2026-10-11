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

    // MARK: Typed mapping records

    /// A `mapping-provenance.json` holds the mapper's executable and conda environment, and no app
    /// version, OS, process ID, architecture, dependency set, account or workflow version. The
    /// finder reads a mapping folder without its `.lungfish-provenance.json` through it.
    func testTheFinderReadsASavedMappingRecordWithoutTheReadingMacsFacts() throws {
        let mapping = try Self.saveMappingRecord()
        defer { mapping.cleanup() }
        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: mapping.folder))
        XCTAssertEqual(found.sidecarURL.lastPathComponent, MappingProvenance.filename)
        assertHoldsOnlyTheMappingRecordsFacts(found.envelope)
    }

    /// Lineage finds the mapping record as the producer of a consumer's input by its checksum.
    func testLineageReadsASavedMappingRecordWithoutTheReadingMacsFacts() throws {
        let mapping = try Self.saveMappingRecord()
        defer { mapping.cleanup() }
        let consumer = ProvenanceEnvelope(
            createdAt: mapping.recordedAt.addingTimeInterval(60),
            workflowName: "variants call",
            toolName: "bcftools",
            argv: ["bcftools", "mpileup"],
            files: [
                ProvenanceFileDescriptor(
                    path: "<workspace>/sample.sorted.bam",
                    checksumSHA256: mapping.bam.sha256,
                    fileSize: mapping.bam.sizeBytes,
                    format: .bam,
                    role: .input
                ),
            ],
            exitStatus: 0,
            status: .completed
        )
        let runs = ProvenanceLineageResolver().resolve(
            envelope: consumer,
            sidecarURL: mapping.project.appendingPathComponent("Analyses/variants/.lungfish-provenance.json")
        )
        let upstream = try XCTUnwrap(runs.first { $0.sidecarURL?.lastPathComponent == MappingProvenance.filename })
        assertHoldsOnlyTheMappingRecordsFacts(upstream.envelope)
    }

    // MARK: Writers

    /// A writer records its own process, so the writer's defaults fill every field as before, except
    /// that it records no process ID and names its own executable `<external>/<file name>`. A
    /// present value encodes as before, without a process ID.
    func testAWriterStillRecordsItsOwnProcess() throws {
        let identity = ProvenanceRuntimeIdentity()
        XCTAssertEqual(identity.appVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(
            identity.executablePath,
            "<external>/" + URL(fileURLWithPath: ProvenanceRuntimeIdentity.currentExecutablePath).lastPathComponent
        )
        XCTAssertNil(identity.processIdentifier)
        XCTAssertEqual(identity.operatingSystemVersion, WorkflowRun.currentHostOS)
        XCTAssertEqual(identity.architecture, ProvenanceRuntimeIdentity.currentArchitecture)

        let written = ProvenanceRuntimeIdentity(
            appVersion: "Lungfish 2026.10.10 (fixture)",
            executablePath: "/usr/local/bin/lungfish-cli",
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
              "executablePath" : "/usr/local/bin/lungfish-cli",
              "operatingSystemVersion" : "macOS 26.0.0 (arm64)"
            }
            """
        )
    }

    // MARK: Helpers

    struct SavedMapping {
        let temporaryRoot: URL
        let project: URL
        let folder: URL
        let recordedAt: Date
        let bam: FileRecord

        func cleanup() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    /// A mapping folder in a project, holding its `mapping-provenance.json` and no
    /// `.lungfish-provenance.json`.
    static func saveMappingRecord() throws -> SavedMapping {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-mapping-reading")
        let project = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Mapping.lungfish", isDirectory: true)
        let folder = project.appendingPathComponent("Analyses/minimap2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reads = folder.appendingPathComponent("reads.fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: reads)
        let reference = folder.appendingPathComponent("reference.fa")
        try Data(">ref\nACGTACGT\n".utf8).write(to: reference)
        let bamURL = folder.appendingPathComponent("sample.sorted.bam")
        try Data("mapped reads".utf8).write(to: bamURL)
        let bam = ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .output)
        let recordedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let mapperArgv = ["minimap2", "-a", reference.path, reads.path]
        let provenance = MappingProvenance(
            mapper: .minimap2,
            modeID: "sr",
            sampleName: "sample",
            pairedEnd: false,
            threads: 2,
            minimumMappingQuality: 0,
            includeSecondary: false,
            includeSupplementary: true,
            advancedArguments: [],
            inputFASTQURLs: [reads],
            referenceFASTAURL: reference,
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: mapperArgv),
            normalizationInvocations: [],
            mapperVersion: "2.30",
            samtoolsVersion: "1.22",
            wallClockSeconds: 3,
            recordedAt: recordedAt,
            outputFiles: [bam],
            steps: [
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.30",
                    command: mapperArgv,
                    inputs: [ProvenanceRecorder.fileRecord(url: reads, format: .fastq, role: .input)],
                    outputs: [bam],
                    exitCode: 0,
                    wallTime: 3
                ),
            ],
            exitStatus: 0
        )
        try provenance.save(to: folder)
        return SavedMapping(temporaryRoot: temporaryRoot, project: project, folder: folder, recordedAt: recordedAt, bam: bam)
    }

    private func assertHoldsOnlyTheMappingRecordsFacts(
        _ envelope: ProvenanceEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(envelope.workflowVersion, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.appVersion, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.processIdentifier, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.operatingSystemVersion, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.architecture, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.dependencySet, file: file, line: line)
        XCTAssertNil(envelope.runtimeIdentity.user, file: file, line: line)
        XCTAssertEqual(envelope.runtimeIdentity.executablePath, "minimap2", file: file, line: line)
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "minimap2", file: file, line: line)
        XCTAssertEqual(envelope.legacyRun?.appVersion, "", file: file, line: line)
        XCTAssertEqual(envelope.legacyRun?.hostOS, "", file: file, line: line)
        XCTAssertNil(envelope.legacyRun?.runtime.user, file: file, line: line)
    }

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
