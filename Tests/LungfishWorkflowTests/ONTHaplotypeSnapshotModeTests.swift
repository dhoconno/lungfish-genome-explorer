// ONTHaplotypeSnapshotModeTests.swift - The mode of the ONT haplotype definition snapshot (M869 HAPLO-SNAPSHOT-MODE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// `writeHaplotypeDefinitionSnapshot` of the ONT barcode pipeline passed `DurableAtomicFileStore.privateMode`, so
/// `artifacts/haplotyping/haplotype-definition.json` read 0600 beside records that read 0644 (Phase 2.13 lane 13.10,
/// M869, fact S-F3). The snapshot is a record, so it takes the store's record mode and follows the umask.
final class ONTHaplotypeSnapshotModeTests: XCTestCase {
    private static let definitionSet = GenotypeHaplotypeDefinitionSet(
        id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
        assayID: "MHC-exon2-miSeq",
        displayName: "Mauritian cynomolgus macaques",
        speciesName: "Mauritian cynomolgus macaque",
        speciesCode: "MCM",
        prefix: "Mafa",
        locusDefinitions: [
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-A",
                sourceLocus: "Mafa-A",
                haplotypes: [GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["A1_063"])]
            ),
        ]
    )

    /// Writes the snapshot under `mask` and returns its `st_mode` permission bits and its bytes.
    private func writeSnapshot(underUmask mask: mode_t) throws -> (mode: mode_t, bytes: Data) {
        let oldMask = umask(mask)
        defer { umask(oldMask) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-haplotype-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("artifacts/haplotyping/haplotype-definition.json")
        let published = try ONTBarcodeDemuxGenotypingPipeline()
            .writeHaplotypeDefinitionSnapshot(Self.definitionSet, to: url)
        defer { published.close() }
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0, "the snapshot must exist")
        return (info.st_mode & 0o777, try Data(contentsOf: url))
    }

    func testTheSnapshotReads0644UnderUmask022LikeEveryRecord() throws {
        let written = try writeSnapshot(underUmask: 0o022)
        XCTAssertEqual(written.mode, 0o644, "st_mode & 0777 of the haplotype snapshot under umask 022")
    }

    func testTheSnapshotFollowsTheUmaskInsteadOfBeingForcedPrivate() throws {
        let written = try writeSnapshot(underUmask: 0o077)
        XCTAssertEqual(written.mode, 0o600, "under umask 077 a record reads 0600 because of the umask")
    }

    func testTheSnapshotBytesAreTheSortedPrettyJSONOfTheDefinitionSet() throws {
        let written = try writeSnapshot(underUmask: 0o022)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertEqual(written.bytes, try encoder.encode(Self.definitionSet))
    }
}
