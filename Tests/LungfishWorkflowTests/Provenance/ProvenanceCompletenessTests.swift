// ProvenanceCompletenessTests.swift - The one completeness rule for provenance records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

/// Pins `ProvenanceCompleteness.issues(in:)`, the rule the Inspector's coverage audit used to
/// keep to itself (Phase 2.4, finding R8, lane W2C). The sentences and their order are what a
/// scientist reads as warnings, so each case compares the whole list.
@Suite("Provenance completeness rule")
struct ProvenanceCompletenessTests {
    private static let digest = String(repeating: "a", count: 64)

    private static func descriptor(
        _ path: String,
        role: FileRole,
        checksum: String? = ProvenanceCompletenessTests.digest,
        size: UInt64? = 12
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: path, checksumSHA256: checksum, fileSize: size, format: .fastq, role: role)
    }

    private static let input = descriptor("/nowhere/lge-completeness/reads.fastq", role: .input)
    private static let output = descriptor("/nowhere/lge-completeness/reads.clumped.fastq", role: .output)

    /// The fields the rule reads. A fresh value is a complete record, and a case changes the
    /// one field it is about.
    private struct Parts {
        var workflowName = "lungfish import fastq"
        var workflowVersion = "2026.10.1"
        var toolName = "clumpify.sh"
        var toolVersion = "40.02"
        var argv = ["clumpify.sh", "in=reads.fastq", "out=reads.clumped.fastq"]
        var reproducibleCommand: String?
        var files = [ProvenanceCompletenessTests.input, ProvenanceCompletenessTests.output]
        var output: ProvenanceFileDescriptor? = ProvenanceCompletenessTests.output
        var outputs = [ProvenanceCompletenessTests.output]
        var steps = [
            ProvenanceStep(
                toolName: "clumpify.sh",
                toolVersion: "40.02",
                argv: ["clumpify.sh", "in=reads.fastq"],
                inputs: [ProvenanceCompletenessTests.input],
                outputs: [ProvenanceCompletenessTests.output],
                exitStatus: 0,
                wallTimeSeconds: 1,
                stderr: ""
            ),
        ]
        var wallTimeSeconds: TimeInterval? = 2
        var exitStatus: Int? = 0
        var stderr: String? = ""

        var envelope: ProvenanceEnvelope {
            ProvenanceEnvelope(
                workflowName: workflowName,
                workflowVersion: workflowVersion,
                toolName: toolName,
                toolVersion: toolVersion,
                argv: argv,
                reproducibleCommand: reproducibleCommand,
                runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
                files: files,
                output: output,
                outputs: outputs,
                steps: steps,
                wallTimeSeconds: wallTimeSeconds,
                exitStatus: exitStatus,
                stderr: stderr
            )
        }
    }

    // MARK: - Complete and incomplete records

    @Test("a record with every field has no issues")
    func completeRecordHasNoIssues() {
        #expect(ProvenanceCompleteness.issues(in: Parts().envelope) == [])
    }

    @Test("an empty record lists every gap, in the order the Inspector shows them")
    func emptyRecordListsEveryGapInOrder() {
        var parts = Parts()
        parts.workflowName = ""
        parts.workflowVersion = "unknown"
        parts.toolName = ""
        parts.toolVersion = "unknown"
        parts.argv = []
        parts.files = []
        parts.output = nil
        parts.outputs = []
        parts.steps = []
        parts.wallTimeSeconds = nil
        parts.exitStatus = nil
        parts.stderr = nil

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "Workflow name is missing.",
            "Workflow version is missing.",
            "Tool name is missing.",
            "Tool version is missing.",
            "Exact argv or reproducible command is missing.",
            "Input/reference/output file descriptors are missing.",
            "Output descriptors are missing.",
            "Workflow step list is missing.",
            "Exit status is missing.",
            "Wall time is missing.",
        ])
    }

    @Test("a name or version that is blank, unknown or any case of unknown counts as missing")
    func unknownNamesAndVersionsCountAsMissing() {
        var parts = Parts()
        parts.workflowName = "  Unknown "
        parts.workflowVersion = "UNKNOWN"
        parts.toolName = "unknown"
        parts.toolVersion = "   "

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "Workflow name is missing.",
            "Workflow version is missing.",
            "Tool name is missing.",
            "Tool version is missing.",
        ])
    }

    // MARK: - What satisfies a requirement

    @Test("an argv or a reproducible command is enough, and either alone satisfies the rule")
    func argvOrReproducibleCommandSatisfiesTheRule() {
        var commandOnly = Parts()
        commandOnly.argv = []
        commandOnly.reproducibleCommand = "lungfish import fastq reads.fastq"
        #expect(ProvenanceCompleteness.issues(in: commandOnly.envelope) == [])

        var argvOnly = Parts()
        argvOnly.reproducibleCommand = "   "
        #expect(ProvenanceCompleteness.issues(in: argvOnly.envelope) == [])

        var neither = Parts()
        neither.argv = []
        neither.reproducibleCommand = "   "
        #expect(ProvenanceCompleteness.issues(in: neither.envelope) == [
            "Exact argv or reproducible command is missing.",
        ])
    }

    @Test("an output is found in the single output, the outputs or a file with the output role")
    func outputDescriptorsAreFoundInAnyOfThreePlaces() {
        var singleOutput = Parts()
        singleOutput.files = [ProvenanceCompletenessTests.input]
        singleOutput.outputs = []
        #expect(ProvenanceCompleteness.issues(in: singleOutput.envelope) == [])

        var listedOutputs = Parts()
        listedOutputs.files = [ProvenanceCompletenessTests.input]
        listedOutputs.output = nil
        #expect(ProvenanceCompleteness.issues(in: listedOutputs.envelope) == [])

        var outputRoleFile = Parts()
        outputRoleFile.output = nil
        outputRoleFile.outputs = []
        #expect(ProvenanceCompleteness.issues(in: outputRoleFile.envelope) == [])

        var none = Parts()
        none.files = [ProvenanceCompletenessTests.input]
        none.output = nil
        none.outputs = []
        #expect(ProvenanceCompleteness.issues(in: none.envelope) == ["Output descriptors are missing."])
    }

    // MARK: - Failed runs

    @Test("a failed run and a failed step each need their stderr")
    func failedRunAndStepNeedTheirStderr() {
        var parts = Parts()
        parts.exitStatus = 2
        parts.stderr = nil
        parts.steps = [
            ProvenanceStep(
                toolName: "clumpify.sh",
                toolVersion: "40.02",
                argv: ["clumpify.sh"],
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: nil
            ),
        ]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "stderr is missing for the failed workflow.",
            "stderr is missing for one or more failed workflow steps.",
        ])

        parts.stderr = ""
        parts.steps = [
            ProvenanceStep(
                toolName: "clumpify.sh",
                toolVersion: "40.02",
                argv: ["clumpify.sh"],
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: ""
            ),
        ]
        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [], "An empty stderr is recorded, so it is not missing.")
    }

    @Test("a succeeded run needs no stderr")
    func succeededRunNeedsNoStderr() {
        var parts = Parts()
        parts.stderr = nil
        parts.steps = [
            ProvenanceStep(
                toolName: "clumpify.sh",
                toolVersion: "40.02",
                argv: ["clumpify.sh"],
                exitStatus: nil,
                wallTimeSeconds: 1,
                stderr: nil
            ),
        ]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [])
    }

    // MARK: - File checksums and sizes

    @Test("file descriptors without a checksum or size are one sentence that names four examples")
    func missingFileMetadataIsOneSentenceNamingFourExamples() {
        let bare = ["a", "b", "c", "d", "e", "f"].map {
            Self.descriptor("/nowhere/lge-completeness/\($0).fastq", role: .input, checksum: nil, size: nil)
        }
        var parts = Parts()
        parts.files = bare + [Self.output]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "Missing checksum or size for 6 file descriptors: a.fastq, b.fastq, c.fastq, d.fastq and 2 more.",
        ])
    }

    @Test("one descriptor is named in the singular, and a half-recorded one counts")
    func oneDescriptorIsSingularAndHalfRecordedCounts() {
        var checksumOnly = Parts()
        checksumOnly.files = [
            Self.descriptor("/nowhere/lge-completeness/reads.fastq", role: .input, checksum: Self.digest, size: nil),
            Self.output,
        ]
        #expect(ProvenanceCompleteness.issues(in: checksumOnly.envelope) == [
            "Missing checksum or size for 1 file descriptor: reads.fastq.",
        ])

        var sizeOnly = Parts()
        sizeOnly.files = [
            Self.descriptor("/nowhere/lge-completeness/reads.fastq", role: .input, checksum: nil, size: 12),
            Self.output,
        ]
        #expect(ProvenanceCompleteness.issues(in: sizeOnly.envelope) == [
            "Missing checksum or size for 1 file descriptor: reads.fastq.",
        ])
    }

    @Test("the same path listed in several places is counted once")
    func samePathIsCountedOnce() {
        let bare = Self.descriptor("/nowhere/lge-completeness/reads.fastq", role: .input, checksum: nil, size: nil)
        var parts = Parts()
        parts.files = [bare, Self.output]
        parts.steps = [
            ProvenanceStep(
                toolName: "clumpify.sh",
                toolVersion: "40.02",
                argv: ["clumpify.sh"],
                inputs: [bare],
                outputs: [Self.output],
                exitStatus: 0,
                wallTimeSeconds: 1,
                stderr: ""
            ),
        ]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "Missing checksum or size for 1 file descriptor: reads.fastq.",
        ])
    }

    @Test("the file sentence comes after the stderr sentences")
    func fileSentenceComesLast() {
        var parts = Parts()
        parts.exitStatus = 1
        parts.stderr = nil
        parts.files = [
            Self.descriptor("/nowhere/lge-completeness/reads.fastq", role: .input, checksum: nil, size: nil),
            Self.output,
        ]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "stderr is missing for the failed workflow.",
            "Missing checksum or size for 1 file descriptor: reads.fastq.",
        ])
    }

    @Test("a piped stream, a directory and a failed step's absent output need no checksum")
    func streamsDirectoriesAndAbsentFailedOutputsAreNotFileGaps() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-completeness-\(UUID().uuidString)", isDirectory: true)
        let keptFile = folder.appendingPathComponent("kept.vcf")
        let absentFile = folder.appendingPathComponent("absent.vcf")
        let subfolder = folder.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("##fileformat=VCFv4.2\n".utf8).write(to: keptFile)

        let stream = Self.descriptor("pipe:stdout:bcftools-mpileup", role: .output, checksum: nil, size: nil)
        let directory = Self.descriptor(subfolder.path, role: .output, checksum: nil, size: nil)
        let absent = Self.descriptor(absentFile.path, role: .output, checksum: nil, size: nil)
        let kept = Self.descriptor(keptFile.path, role: .output, checksum: nil, size: nil)
        var parts = Parts()
        parts.files = [Self.input, Self.output, stream, directory]
        parts.exitStatus = 0
        parts.steps = [
            ProvenanceStep(
                toolName: "bcftools",
                toolVersion: "1.24",
                argv: ["bcftools", "call"],
                inputs: [stream],
                outputs: [absent, kept],
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "failed"
            ),
        ]

        #expect(ProvenanceCompleteness.issues(in: parts.envelope) == [
            "Missing checksum or size for 1 file descriptor: kept.vcf.",
        ])
    }

    // MARK: - The rule only reports

    @Test("a record with gaps is still written, because nothing refuses a write")
    func recordWithGapsIsStillWritten() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-completeness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var parts = Parts()
        parts.toolName = ""

        let sidecar = try ProvenanceWriter(signingProvider: nil).write(parts.envelope, to: folder)

        let reread = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        #expect(ProvenanceCompleteness.issues(in: reread) == ["Tool name is missing."])
    }
}
