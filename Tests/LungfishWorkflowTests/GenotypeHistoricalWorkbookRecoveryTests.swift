import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

/// Literal historical generations and the retained public WAL/attestation seam.
/// No renderer, importer, updater, or alternate publication engine is a fixture dependency.
final class GenotypeHistoricalWorkbookRecoveryTests: XCTestCase {
    private struct Interrupted: Error {}
    private let checkpoints = [
        "after-workbook-cleanup-detach-hard-stop",
        "after-workbook-cleanup-state-write-before-attestation-hard-stop",
        "after-workbook-cleanup-state-durable-hard-stop",
        "after-workbook-cleanup-marker-removal-hard-stop",
        "after-workbook-cleanup-attestation-removal-hard-stop",
    ]

    func testHistoricalCleanupRecoversEveryBranchAtEveryDurabilityBoundary() throws {
        for branch in ["prepared", "exchanged", "committed", "manual-winner"] {
            for checkpoint in checkpoints {
                let fixture = try Fixture(branch: branch)
                defer { fixture.dispose() }
                XCTAssertThrowsError(try fixture.recover { observed in
                    if observed == checkpoint { throw Interrupted() }
                }, "\(branch) / \(checkpoint)")
                try fixture.recover()
                try fixture.assertWinner(branch == "committed" ? Fixture.newBytes
                    : branch == "manual-winner" ? Fixture.editedBytes : Fixture.oldBytes)
                try fixture.assertRetired()
            }
        }
    }

    func testHistoricalThreeRenameRotationRecoversAtAllThreeInterruptedSteps() throws {
        for step in 1...3 {
            let fixture = try Fixture(branch: "prepared")
            defer { fixture.dispose() }
            try FileManager.default.moveItem(at: fixture.staging, to: fixture.rotation)
            if step >= 2 { try FileManager.default.moveItem(at: fixture.bundle, to: fixture.staging) }
            if step >= 3 { try FileManager.default.moveItem(at: fixture.rotation, to: fixture.bundle) }
            try fixture.recover()
            try fixture.assertWinner(Fixture.oldBytes)
            try fixture.assertRetired()
        }
    }

    func testHistoricalMissingOrTornMarkerRehydratesFromDetachedAttestation() throws {
        for missing in [false, true] {
            let fixture = try Fixture(branch: "exchanged")
            defer { fixture.dispose() }
            if missing { try FileManager.default.removeItem(at: fixture.marker) }
            else { try Data("{torn".utf8).write(to: fixture.marker) }
            try fixture.recover()
            try fixture.assertWinner(Fixture.oldBytes)
            try fixture.assertRetired()
        }
    }

    func testHistoricalCommittedGenerationPreservesLaterManualEdit() throws {
        let fixture = try Fixture(branch: "committed")
        defer { fixture.dispose() }
        try Fixture.editedBytes.write(to: fixture.current(in: fixture.bundle))
        try fixture.recover()
        try fixture.assertWinner(Fixture.editedBytes)
        try fixture.assertRetired()
    }

    func testHistoricalBothEditedGenerationsFailClosed() throws {
        let fixture = try Fixture(branch: "committed")
        defer { fixture.dispose() }
        try Data("new generation edited".utf8).write(to: fixture.current(in: fixture.bundle))
        try Data("old generation edited".utf8).write(to: fixture.current(in: fixture.staging))
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertEqual(try Data(contentsOf: fixture.current(in: fixture.bundle)), Data("new generation edited".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.current(in: fixture.staging)), Data("old generation edited".utf8))
    }

    func testHistoricalMissingCorruptOrSymlinkedAttestationCannotMutateEitherGeneration() throws {
        for mutation in ["missing", "corrupt", "symlink"] {
            let fixture = try Fixture(branch: "exchanged")
            defer { fixture.dispose() }
            let attestation = fixture.attestations.appendingPathComponent(try XCTUnwrap(fixture.transaction.attestationID) + ".json")
            let exact = try Data(contentsOf: attestation)
            try FileManager.default.removeItem(at: attestation)
            if mutation == "corrupt" { try Data("not authority".utf8).write(to: attestation) }
            if mutation == "symlink" {
                let outside = fixture.root.appendingPathComponent("unrelated-attestation.json")
                try exact.write(to: outside)
                try FileManager.default.createSymbolicLink(at: attestation, withDestinationURL: outside)
            }
            XCTAssertThrowsError(try fixture.recover(), mutation)
            try fixture.assertBothGenerationBytes()
        }
    }

    func testHistoricalMarkerCannotRedirectToByteIdenticalUnrelatedStage() throws {
        let fixture = try Fixture(branch: "exchanged")
        defer { fixture.dispose() }
        let other = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.copyItem(at: fixture.staging, to: other)
        try fixture.mutateJSON(fixture.marker) { $0["stagingBundlePath"] = other.path }
        XCTAssertThrowsError(try fixture.recover())
        try fixture.assertBothGenerationBytes()
        XCTAssertEqual(try Data(contentsOf: fixture.current(in: other)), Fixture.oldBytes)
    }

    func testHistoricalTransactionRootInodeAndSymlinkSubstitutionAreRejected() throws {
        for symlink in [false, true] {
            let fixture = try Fixture(branch: "exchanged")
            defer { fixture.dispose() }
            let preserved = fixture.root.appendingPathComponent("preserved-transaction")
            try FileManager.default.moveItem(at: fixture.transactionRoot, to: preserved)
            if symlink {
                try FileManager.default.createSymbolicLink(at: fixture.transactionRoot, withDestinationURL: preserved)
            } else {
                try FileManager.default.copyItem(at: preserved, to: fixture.transactionRoot)
            }
            XCTAssertThrowsError(try fixture.recover())
            XCTAssertEqual(try Data(contentsOf: fixture.current(in: fixture.bundle)), Fixture.newBytes)
            XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent(fixture.bundle.lastPathComponent).appendingPathComponent(Fixture.currentPath)), Fixture.oldBytes)
        }
    }

    func testHistoricalMarkerlessCleanupRejectsMissingSubstitutedOrCorruptSurvivor() throws {
        for mutation in ["missing", "substituted", "corrupt"] {
            let fixture = try Fixture(branch: "committed")
            defer { fixture.dispose() }
            XCTAssertThrowsError(try fixture.recover { observed in
                if observed == "after-workbook-cleanup-attestation-removal-hard-stop" { throw Interrupted() }
            })
            let preserved = fixture.root.appendingPathComponent("preserved-survivor")
            if mutation == "corrupt" {
                try Data("corrupt workbook".utf8).write(to: fixture.current(in: fixture.bundle))
            } else {
                try FileManager.default.moveItem(at: fixture.bundle, to: preserved)
                if mutation == "substituted" { try FileManager.default.copyItem(at: preserved, to: fixture.bundle) }
            }
            let quarantine = try fixture.quarantine()
            XCTAssertThrowsError(try fixture.recover(), mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        }
    }

    func testHistoricalCleanupNeverDeletesSubstitutedQuarantineInode() throws {
        let fixture = try Fixture(branch: "committed")
        defer { fixture.dispose() }
        XCTAssertThrowsError(try fixture.recover { observed in
            if observed == "after-workbook-cleanup-state-durable-hard-stop" { throw Interrupted() }
        })
        let quarantine = try fixture.quarantine()
        let preserved = fixture.root.appendingPathComponent("preserved-quarantine")
        try FileManager.default.moveItem(at: quarantine, to: preserved)
        try FileManager.default.copyItem(at: preserved, to: quarantine)
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        try fixture.assertWinner(Fixture.newBytes)
    }

    func testHistoricalReadOnlyLoaderDoesNotCreateAdjacentLock() throws {
        let fixture = try Fixture(branch: "prepared")
        defer { fixture.dispose() }
        try fixture.recover()
        let lock = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundle)
        if FileManager.default.fileExists(atPath: lock.path) { try FileManager.default.removeItem(at: lock) }
        XCTAssertEqual(chmod(fixture.bundle.path, 0o555), 0)
        XCTAssertEqual(chmod(fixture.root.path, 0o555), 0)
        defer { _ = chmod(fixture.root.path, 0o755); _ = chmod(fixture.bundle.path, 0o755) }
        XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: fixture.bundle).calls.first?.passedUniqueReads, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testHistoricalPublicLoaderRecoversPreparedAndExchangedGenerations() throws {
        for branch in ["prepared", "exchanged"] {
            let fixture = try Fixture(branch: branch, defaultAttestations: true)
            defer { fixture.dispose() }
            let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundle)
            XCTAssertEqual(loaded.calls.map(\.passedUniqueReads), [7])
            XCTAssertEqual(loaded.manifest.analysisName, "historical-old")
            try fixture.assertWinner(Fixture.oldBytes)
            try fixture.assertRetired()
        }
    }

    func testHistoricalAsyncLoaderFinalizesCommittedGenerationAndAllowsLaterExternalEdit() async throws {
        let fixture = try Fixture(branch: "committed", defaultAttestations: true)
        defer { fixture.dispose() }
        let loaded = try await ONTGenotypeResultBundle.loadResultAsync(from: fixture.bundle)
        XCTAssertEqual(loaded.manifest.analysisName, "historical-new")
        try fixture.assertWinner(Fixture.newBytes)
        try fixture.assertRetired()
        try Fixture.editedBytes.write(to: fixture.current(in: fixture.bundle))
        XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: fixture.bundle).calls.map(\.passedUniqueReads), [7])
        try fixture.assertWinner(Fixture.editedBytes)
    }

    func testHistoricalCleanupTraversalFailurePreservesEveryWinnerAndCanRetry() throws {
        for branch in ["prepared", "exchanged", "committed", "manual-winner"] {
            let fixture = try Fixture(branch: branch)
            defer { fixture.dispose() }
            XCTAssertThrowsError(try fixture.recover { observed in
                if observed == "during-workbook-cleanup-traversal" { throw Interrupted() }
            })
            let winner = branch == "committed" ? Fixture.newBytes : branch == "manual-winner" ? Fixture.editedBytes : Fixture.oldBytes
            try fixture.assertWinner(winner)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.quarantine().path))
            try fixture.recover()
            try fixture.assertWinner(winner)
            try fixture.assertRetired()
        }
    }

    func testHistoricalCleanupStateTamperingCannotForgeDerivedDeletionAuthority() throws {
        for checkpoint in ["after-workbook-cleanup-state-durable-hard-stop", "after-workbook-cleanup-attestation-removal-hard-stop"] {
            for field in ["finalBundlePath", "sourceRootPath", "quarantinePath", "survivorManifest", "survivorCurrentWorkbook", "terminalReceiptAction", "decision", "transaction"] {
                let fixture = try Fixture(branch: "committed")
                defer { fixture.dispose() }
                XCTAssertThrowsError(try fixture.recover { observed in if observed == checkpoint { throw Interrupted() } })
                let state = ONTGenotypeWorkbookCleanupStateStore.stateURL(transactionID: fixture.transaction.transactionID, bundleURL: fixture.bundle)
                let quarantine = try fixture.quarantine()
                try fixture.mutateJSON(state) { value in
                    if field == "transaction" {
                        var transaction = try XCTUnwrap(value[field] as? [String: Any])
                        transaction["stagingBundlePath"] = fixture.root.appendingPathComponent("unrelated").path
                        value[field] = transaction
                    } else if field == "survivorManifest" || field == "survivorCurrentWorkbook" {
                        var descriptor = try XCTUnwrap(value[field] as? [String: Any])
                        descriptor["sha256"] = String(repeating: "0", count: 64)
                        value[field] = descriptor
                    } else { value[field] = "forged" }
                }
                XCTAssertThrowsError(try fixture.recover(), "\(checkpoint) / \(field)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path), field)
                try fixture.assertWinner(Fixture.newBytes)
            }
        }
    }

    func testHistoricalMultipleMarkerHintsOrAttestationsFailClosed() throws {
        for duplicate in ["marker", "attestation"] {
            let fixture = try Fixture(branch: "exchanged")
            defer { fixture.dispose() }
            let original = duplicate == "marker" ? fixture.marker
                : fixture.attestations.appendingPathComponent(try XCTUnwrap(fixture.transaction.attestationID) + ".json")
            let destination = duplicate == "marker"
                ? fixture.root.appendingPathComponent(".\(fixture.bundle.lastPathComponent).workbook-update-transaction-\(UUID().uuidString).json")
                : fixture.attestations.appendingPathComponent("duplicate.json")
            try FileManager.default.copyItem(at: original, to: destination)
            XCTAssertThrowsError(try fixture.recover())
            try fixture.assertBothGenerationBytes()
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testHistoricalRetirementNeverDeletesSubstitutedAuthorityOrQuarantine() throws {
        for kind in ["marker", "attestation", "quarantine", "state"] {
            let fixture = try Fixture(branch: "committed")
            defer { fixture.dispose() }
            let held = fixture.root.appendingPathComponent("held-authentic-\(kind)")
            let replacement = Data("literal substituted \(kind) must survive".utf8)
            let target: URL
            switch kind {
            case "marker": target = fixture.marker
            case "attestation":
                target = fixture.attestations.appendingPathComponent(try XCTUnwrap(fixture.transaction.attestationID) + ".json")
            case "quarantine": target = try fixture.quarantine()
            default:
                target = ONTGenotypeWorkbookCleanupStateStore.stateURL(transactionID: fixture.transaction.transactionID, bundleURL: fixture.bundle)
            }
            XCTAssertThrowsError(try fixture.recover { checkpoint in
                guard checkpoint.hasPrefix("before-workbook-cleanup-\(kind)-detach:") else { return }
                try FileManager.default.moveItem(at: target, to: held)
                if kind == "quarantine" {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                } else {
                    try replacement.write(to: target)
                }
            }, kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), kind)
            if kind != "quarantine" { XCTAssertEqual(try Data(contentsOf: target), replacement, kind) }
            try fixture.assertWinner(Fixture.newBytes)
        }
    }

    func testHistoricalPostWitnessMarkerTombstoneSubstitutionIsPreserved() throws {
        let fixture = try Fixture(branch: "committed")
        defer { fixture.dispose() }
        let original = try Data(contentsOf: fixture.marker)
        let held = fixture.root.appendingPathComponent("held-marker")
        let replacement = Data("literal foreign tombstone".utf8)
        let markerPath = fixture.marker.path
        let root = fixture.root
        XCTAssertThrowsError(try fixture.recover { checkpoint in
            guard checkpoint.hasPrefix("after-workbook-retirement-witness:"),
                  checkpoint.hasSuffix(markerPath) else { return }
            let tombstones = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".lungfish-workbook-retiring-") }
            XCTAssertEqual(tombstones.count, 1)
            let tombstone = try XCTUnwrap(tombstones.first)
            try FileManager.default.moveItem(at: tombstone, to: held)
            try replacement.write(to: tombstone)
        })
        XCTAssertEqual(try Data(contentsOf: held), original)
        let tombstones = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".lungfish-workbook-retiring-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(tombstones.first)), replacement)
        try fixture.assertWinner(Fixture.newBytes)
    }

    func testHistoricalMarkerlessCleanupRejectsMissingReceiptAndCoherentReplacementState() throws {
        for mutation in ["missing-attestation", "coherent-state"] {
            let fixture = try Fixture(branch: "committed")
            defer { fixture.dispose() }
            XCTAssertThrowsError(try fixture.recover { checkpoint in
                if checkpoint == "after-workbook-cleanup-attestation-removal-hard-stop" { throw Interrupted() }
            })
            if mutation == "missing-attestation" {
                let receipt = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.attestations, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasSuffix(".workbook-cleanup.json") })
                try FileManager.default.removeItem(at: receipt)
            } else {
                let state = ONTGenotypeWorkbookCleanupStateStore.stateURL(transactionID: fixture.transaction.transactionID, bundleURL: fixture.bundle)
                try fixture.mutateJSON(state) { $0["createdAt"] = "2036-01-02T03:04:05Z" }
            }
            XCTAssertThrowsError(try fixture.recover { checkpoint in
                XCTAssertNotEqual(checkpoint, "during-workbook-cleanup-traversal")
            }, mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.quarantine().path))
            try fixture.assertWinner(Fixture.newBytes)
        }
    }

    func testHistoricalMarkerlessCleanupDiscoveryUsesActualBundleCasing() throws {
        let fixture = try Fixture(branch: "committed")
        defer { fixture.dispose() }
        XCTAssertThrowsError(try fixture.recover { checkpoint in
            if checkpoint == "after-workbook-cleanup-attestation-removal-hard-stop" { throw Interrupted() }
        })
        let alias = fixture.root.appendingPathComponent(fixture.bundle.lastPathComponent.uppercased())
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("Volume is case-sensitive") }
        let lock = try ONTGenotypeBundlePublicationLock.acquire(for: fixture.bundle)
        defer { lock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(for: alias, attestationRootURL: fixture.attestations)
        try fixture.assertWinner(Fixture.newBytes)
        try fixture.assertRetired()
    }

    private final class Fixture {
        static let currentPath = "artifacts/workbooks/current.xlsx"
        static let oldBytes = Data("PK\u{3}\u{4}literal historical original".utf8)
        static let newBytes = Data("PK\u{3}\u{4}literal historical replacement".utf8)
        static let editedBytes = Data("PK\u{3}\u{4}literal later analyst save".utf8)
        let root: URL
        let bundle: URL
        let staging: URL
        let transactionRoot: URL
        let rotation: URL
        let attestations: URL
        let transaction: ONTGenotypeWorkbookUpdateTransaction
        var marker: URL { ONTGenotypeWorkbookUpdateRecovery.markerURL(for: bundle) }

        init(branch: String, defaultAttestations: Bool = false) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("HistoricalWorkbook-\(UUID().uuidString)")
            bundle = root.appendingPathComponent("result.lungfishgenotype")
            let id = UUID().uuidString
            transactionRoot = root.appendingPathComponent(".result.lungfishgenotype.workbook-update-\(id).staging")
            staging = transactionRoot.appendingPathComponent(bundle.lastPathComponent)
            rotation = transactionRoot.appendingPathComponent(".publication-rotation")
            attestations = defaultAttestations ? try ONTGenotypeWorkbookUpdateRecovery.defaultAttestationRootURL() : root.appendingPathComponent("attestations")
            try fm.createDirectory(at: bundle.appendingPathComponent("artifacts/workbooks"), withIntermediateDirectories: true)
            try Self.oldBytes.write(to: bundle.appendingPathComponent(Self.currentPath))
            try Data("sample,genotype,passed_alignments,passed_unique_reads\nSample-A,01_Mafa_A1,9,7\n".utf8).write(to: bundle.appendingPathComponent("calls.csv"))
            try Data("sample,passed_alignments,passed_unique_reads\nSample-A,9,7\n".utf8).write(to: bundle.appendingPathComponent("samples.csv"))
            try Data("{\"totalInputReads\":10,\"retainedUniqueReads\":7}".utf8).write(to: bundle.appendingPathComponent("stats.json"))
            try Data("{}".utf8).write(to: bundle.appendingPathComponent("provenance.json"))
            let manifest = ONTGenotypeResultBundleManifest(kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
                workflowKind: .miSeqAmpliconMHCGenotype, workflowMode: .genotypeOnly,
                outputName: "historical", analysisName: "historical-old", primaryWorkbookPath: Self.currentPath,
                currentWorkbookPath: Self.currentPath, longSummaryCSVPath: "calls.csv", sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json", provenancePath: "provenance.json")
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
            // Real historical writers created the adjacent lock before publishing a WAL.
            try ONTGenotypeBundlePublicationLock.acquire(for: bundle).release()
            let manifestPath = ONTGenotypeResultBundleManifest.filename
            let oldManifest = try Data(contentsOf: bundle.appendingPathComponent(manifestPath))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldManifest) as? [String: Any])
            object["analysisName"] = "historical-new"
            let newManifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try fm.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: bundle, to: staging)
            try Self.newBytes.write(to: staging.appendingPathComponent(Self.currentPath))
            let recovery = ONTGenotypeWorkbookUpdateRecovery.self
            transaction = try recovery.createAttestation(for: .init(transactionID: id,
                finalBundlePath: bundle.path, stagingBundlePath: staging.path, transactionRootPath: transactionRoot.path,
                rotationTemporaryPath: rotation.path, workflowName: "historical-workbook-update", toolName: "lungfish-cli",
                toolVersion: "historical-fixture", argv: ["lungfish-cli", "fastq", "update-current-workbook", bundle.path],
                durableReplayArgv: ["historical-command-no-longer-supported"], resolvedOptions: [:], runtimeIdentity: [:],
                oldManifest: recovery.descriptor(for: oldManifest, path: manifestPath),
                newManifest: recovery.descriptor(for: newManifest, path: manifestPath),
                oldCurrentWorkbook: recovery.descriptor(for: Self.oldBytes, path: Self.currentPath),
                newCurrentWorkbook: recovery.descriptor(for: Self.newBytes, path: Self.currentPath),
                oldGenerationIdentity: recovery.directoryIdentity(for: bundle, path: bundle.path),
                newGenerationIdentity: recovery.directoryIdentity(for: staging, path: staging.path),
                transactionRootIdentity: recovery.directoryIdentity(for: transactionRoot, path: transactionRoot.path),
                finalParentIdentity: recovery.directoryIdentity(for: root, path: root.path)), attestationRootURL: attestations)
            try recovery.write(transaction, for: bundle, attestationRootURL: attestations)
            if branch != "prepared" {
                // Simulate only the on-disk interrupted state, not publication logic.
                try fm.moveItem(at: staging, to: rotation)
                try fm.moveItem(at: bundle, to: staging)
                try fm.moveItem(at: rotation, to: bundle)
            }
            if branch == "committed" || branch == "manual-winner" {
                try newManifest.write(to: bundle.appendingPathComponent(manifestPath))
            }
            if branch == "manual-winner" { try Self.editedBytes.write(to: staging.appendingPathComponent(Self.currentPath)) }
        }

        func current(in directory: URL) -> URL { directory.appendingPathComponent(Self.currentPath) }
        func recover(_ inject: (@Sendable (String) throws -> Void)? = nil) throws {
            let lock = try ONTGenotypeBundlePublicationLock.acquire(for: bundle)
            defer { lock.release() }
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(for: bundle,
                attestationRootURL: attestations, cleanupFailureInjector: inject)
        }
        func assertWinner(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: current(in: bundle)), bytes, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("calls.csv")),
                Data("sample,genotype,passed_alignments,passed_unique_reads\nSample-A,01_Mafa_A1,9,7\n".utf8), file: file, line: line)
        }
        func assertBothGenerationBytes() throws {
            XCTAssertEqual(try Data(contentsOf: current(in: bundle)), Self.newBytes)
            XCTAssertEqual(try Data(contentsOf: current(in: staging)), Self.oldBytes)
        }
        func quarantine() throws -> URL {
            ONTGenotypeWorkbookCleanupStateStore.quarantineURL(transactionID: transaction.transactionID, parent: root)
        }
        func assertRetired() throws {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: transactionRoot.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lungfish-workbook-generation-archive-") })
        }
        func mutateJSON(_ url: URL, _ mutation: (inout [String: Any]) throws -> Void) throws {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            try mutation(&value)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        }
        func dispose() {
            if let id = transaction.attestationID { try? FileManager.default.removeItem(at: attestations.appendingPathComponent(id + ".json")) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
