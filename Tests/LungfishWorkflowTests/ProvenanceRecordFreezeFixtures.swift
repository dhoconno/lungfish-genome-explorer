// ProvenanceRecordFreezeFixtures.swift - The cleanup and mapping records whose bytes Phase 2.13 lane 13.12 froze
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

/// The records of rows 1 to 9 of the 13.12 ruling (`BIO-13.12.md` F2), built from fixed ids, paths and dates, and the
/// bytes the base `ca0fc49c5` wrote for each, kept in `Tests/Fixtures/provenance-record-freeze`. The bytes were taken
/// with `ProvenanceJSON.encoder` before any encode moved (QA 1), and they must never be captured again.
enum ProvenanceRecordFreezeFixtures {
    static var folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/provenance-record-freeze", isDirectory: true)
    }

    static func assertBytes(
        _ data: Data,
        equalFixture name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try Data(contentsOf: folder.appendingPathComponent(name))
        XCTAssertEqual(
            data,
            expected,
            "\(name) moved. It now reads:\n\(String(decoding: data, as: UTF8.self))",
            file: file,
            line: line
        )
    }

    // MARK: - Fixed facts

    static let projectRoot = "/Volumes/Frozen/Study.lungfish"
    static let cleanupID = UUID(uuidString: "6C1E2A57-0D5B-4B8E-9A43-2F0D4C7B1A01")!
    static let failureID = UUID(uuidString: "6C1E2A57-0D5B-4B8E-9A43-2F0D4C7B1A02")!
    static let itemID = UUID(uuidString: "6C1E2A57-0D5B-4B8E-9A43-2F0D4C7B1A03")!
    static let stepID = UUID(uuidString: "6C1E2A57-0D5B-4B8E-9A43-2F0D4C7B1A04")!
    static let startedAt = Date(timeIntervalSince1970: 1_792_400_000)
    static let completedAt = Date(timeIntervalSince1970: 1_792_400_042)
    static let projectIdentity = FileSystemObjectIdentity(device: 16_777_234, inode: 4_242)
    static let sourceIdentity = FileSystemObjectIdentity(device: 16_777_234, inode: 4_343)
    static let sourceRelativePath = ".lungfish-work/map-01"
    static let operationRoot = projectRoot + "/.lungfish/operations/" + cleanupID.uuidString
    static let digest = String(repeating: "ab", count: 32)
    static let otherDigest = String(repeating: "cd", count: 32)
    static let argv = ["lungfish-cli", "project", "storage", "clean", projectRoot, "--item", sourceRelativePath]

    static let runtimeIdentity = ProvenanceRuntimeIdentity(
        appVersion: "2026.10.21",
        executablePath: "<external>/lungfish-cli",
        processIdentifier: nil,
        operatingSystemVersion: "macOS 26.0",
        architecture: "arm64",
        user: nil,
        dependencySet: "lungfish-tools-2026.10"
    )

    static let options = ProvenanceOptions(
        explicit: ["project": .string(projectRoot), "items": .array([.string(sourceRelativePath)])],
        resolvedDefaults: ["action": .string("move-to-trash")]
    )

    static let inventoryEntry = ProjectStorageCleanupInventoryEntry(
        relativePath: "reads/sample.fastq.gz",
        logicalSize: 1_048_576,
        allocatedSize: 1_052_672,
        sha256: digest,
        device: 16_777_234,
        inode: 4_444,
        modifiedSeconds: 1_792_300_000,
        modifiedNanoseconds: 125_000_000,
        changedSeconds: 1_792_300_001,
        changedNanoseconds: 250_000_000
    )

    // MARK: - Rows 5, 7 and 9, the envelopes

    /// Row 9, the preparation envelope of `ProjectStorageCleanupReceiptWriter.swift:445-464`.
    static func preparationEnvelope() -> ProvenanceEnvelope {
        let journal = ProvenanceFileDescriptor(
            path: operationRoot + "/journal.json",
            checksumSHA256: otherDigest,
            fileSize: 2_048,
            format: .json,
            role: .output
        )
        let input = ProvenanceFileDescriptor(
            path: projectRoot + "/" + sourceRelativePath + "/reads/sample.fastq.gz",
            checksumSHA256: digest,
            fileSize: 1_048_576,
            role: .input,
            originPath: sourceRelativePath + "/reads/sample.fastq.gz"
        )
        return envelope(
            workflowName: "Project Storage Cleanup Preparation",
            files: [input],
            output: journal,
            outputs: [journal],
            exitStatus: 0,
            stderr: ""
        )
    }

    /// Row 7, the execution envelope of `ProjectStorageCleanupExecutor.swift:2010-2027`.
    static func executionEnvelope() -> ProvenanceEnvelope {
        let authority = ProvenanceFileDescriptor(
            path: operationRoot + "/provenance.json",
            checksumSHA256: digest,
            fileSize: 4_096,
            format: .json,
            role: .input
        )
        let summary = ProvenanceFileDescriptor(
            path: operationRoot + "/execution-summary-00000001.json",
            checksumSHA256: otherDigest,
            fileSize: 1_024,
            format: .json,
            role: .output
        )
        return envelope(
            workflowName: "Project Storage Cleanup Execution",
            files: [authority],
            output: nil,
            outputs: [summary],
            exitStatus: 0,
            stderr: ""
        )
    }

    /// Row 5, the failure envelope of `ProjectStorageAutomaticCleanupService.swift:612-629`.
    static func failureEnvelope() -> ProvenanceEnvelope {
        let project = ProvenanceFileDescriptor(path: projectRoot, role: .input)
        let summary = ProvenanceFileDescriptor(
            path: projectRoot + "/.lungfish/operations/" + failureID.uuidString + "/automatic-cleanup-failure.json",
            checksumSHA256: otherDigest,
            fileSize: 512,
            format: .json,
            role: .output
        )
        return envelope(
            id: failureID,
            workflowName: "Project Temporary Storage Cleanup Failure",
            files: [project],
            output: nil,
            outputs: [summary],
            exitStatus: 1,
            stderr: "The project folder could not be read."
        )
    }

    private static func envelope(
        id: UUID = cleanupID,
        workflowName: String,
        files: [ProvenanceFileDescriptor],
        output: ProvenanceFileDescriptor?,
        outputs: [ProvenanceFileDescriptor],
        exitStatus: Int,
        stderr: String
    ) -> ProvenanceEnvelope {
        let step = ProvenanceStep(
            id: stepID,
            toolName: "lungfish-cli",
            toolVersion: "2026.10.21",
            argv: argv,
            durableReplayArgv: argv,
            resolvedOptions: options.explicit,
            runtimeIdentity: runtimeIdentity,
            inputs: files,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: 42,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return ProvenanceEnvelope(
            id: id,
            createdAt: completedAt,
            workflowName: workflowName,
            workflowVersion: "2026.10.21",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.21",
            argv: argv,
            durableReplayArgv: argv,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: 42,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }
}
