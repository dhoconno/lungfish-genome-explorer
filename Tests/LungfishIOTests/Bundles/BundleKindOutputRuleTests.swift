// BundleKindOutputRuleTests.swift - Which files of a bundle are never outputs of its record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The writer-wide record rule (plan decision V10 and Phase 2.7 decision P6) as the registry answers
// it. A record file, the signature or key file of a record and the app state a kind declares are
// never outputs. A manifest and a typed record always are, and a kind with a frozen record format
// drops nothing. BundleKindAgreementTests in the Workflow tests checks the names against the writer
// and the signer, which this module cannot see.

import Foundation
import XCTest
@testable import LungfishIO

final class BundleKindOutputRuleTests: XCTestCase {
    private func excluded(_ path: String, inBundle name: String) -> Bool {
        BundleKindRegistry.excludesFromBundleOutputs(
            relativePath: path,
            inBundleAt: URL(fileURLWithPath: "/project/Analyses/\(name)", isDirectory: true)
        )
    }

    private static func isFrozen(_ descriptor: BundleKindDescriptor) -> Bool {
        if case .frozenException = descriptor.sidecarNaming { return true }
        return false
    }

    /// One folder name for each registry kind that follows the standard rule, the project folder
    /// included, and two whose extension names no kind.
    private static var standardBundles: [String] {
        BundleKindRegistry.all.filter { !isFrozen($0) }.flatMap(\.folderExtensions).map { "x.\($0)" }
            + ["x.lungfishfuture", "plain"]
    }

    /// One folder name for each registry kind that keeps its own record format.
    private static var frozenBundles: [String] {
        BundleKindRegistry.all.filter(isFrozen).flatMap(\.folderExtensions).map { "x.\($0)" }
    }

    // MARK: - Record files and their signing files

    func testEveryFormOfRecordFileIsNeverAnOutput() {
        let records = [
            ".lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json",
            "bundle.lungfish-provenance.json",
            "tracks/variants.vcf.gz.lungfish-provenance.json",
            "a/b/c.lungfish-provenance.json",
        ]
        XCTAssertEqual(Self.standardBundles.count, 11 + 2, "eleven kinds follow the standard rule, the project folder among them, and two names have no kind")
        for bundle in Self.standardBundles {
            for record in records {
                XCTAssertTrue(excluded(record, inBundle: bundle), "\(record) in \(bundle)")
            }
        }
    }

    func testTheSignatureAndTheKeyOfARecordAreNeverOutputs() {
        let signingFiles = [
            ".lungfish-provenance.json.signature.json",
            ".lungfish-provenance.json.pub",
            "sequence.fa.lungfish-provenance.json.signature.json",
            "tracks/sequence.fa.lungfish-provenance.json.pub",
        ]
        for bundle in Self.standardBundles {
            for file in signingFiles {
                XCTAssertTrue(excluded(file, inBundle: bundle), "\(file) in \(bundle)")
            }
        }
    }

    func testASignatureOrKeyNameThatDoesNotBelongToARecordStaysAnOutput() {
        for bundle in Self.standardBundles {
            for file in ["report.pub", "notes.signature.json", "sequence.fa.signature.json", "key.pub", ".pub", "lungfish-provenance.json.pub"] {
                XCTAssertFalse(excluded(file, inBundle: bundle), "\(file) in \(bundle)")
            }
        }
    }

    // MARK: - What stays

    func testManifestsTypedRecordsAndScientificFilesStayOutputs() {
        // A reference manifest decides which tracks the bundle shows, and the genotype roll-up cites
        // the digest of each typed record, so none of them leaves the outputs.
        let outputs = [
            "manifest.json",
            "genotype-result.json",
            "retained-demux-genotyping-provenance.json",
            "SIMULATED-MHC-haplotypes.xlsx.provenance.json",
            "reads.fastq.gz.lungfish-meta.json",
            "sequence.fa",
            "lungfish-provenance.json",
            "notes-provenance.json",
            "provenance-notes.json",
            "annotations.json",
        ]
        for bundle in Self.standardBundles + Self.frozenBundles {
            for output in outputs {
                XCTAssertFalse(excluded(output, inBundle: bundle), "\(output) in \(bundle)")
            }
        }
    }

    // MARK: - App state

    func testDeclaredAppStateIsDroppedAtTheRootOfItsOwnKindOnly() {
        let declared = BundleKindRegistry.all.flatMap { descriptor in descriptor.appStateFileNames.map { (descriptor, $0) } }
        XCTAssertEqual(declared.map { $0.1 }, [".viewstate.json", ".genotype-viewstate.json"], "two kinds declare app state")
        for (descriptor, name) in declared {
            for ext in descriptor.folderExtensions {
                XCTAssertTrue(excluded(name, inBundle: "x.\(ext)"), "\(name) in \(descriptor.id)")
                XCTAssertTrue(excluded("./\(name)", inBundle: "x.\(ext)"), "\(name) spelled with a leading dot slash")
                XCTAssertFalse(excluded("tracks/\(name)", inBundle: "x.\(ext)"), "\(name) one level down in \(descriptor.id)")
            }
            for bundle in Self.standardBundles + Self.frozenBundles {
                let kind = BundleKindRegistry.descriptor(forLowercasedExtensionOf: URL(fileURLWithPath: bundle))
                if kind?.id != descriptor.id {
                    XCTAssertFalse(excluded(name, inBundle: bundle), "\(name) in \(bundle), which does not declare it")
                }
            }
        }
    }

    func testTheViewStateOfAnAlignmentOrTreeIsNotAppState() {
        // Its creation writes it and the manifest checksums cover it (plan row S11).
        XCTAssertFalse(excluded(".viewstate.json", inBundle: "x.lungfishmsa"))
        XCTAssertFalse(excluded(".viewstate.json", inBundle: "x.lungfishtree"))
        XCTAssertFalse(excluded(".viewstate.json", inBundle: "x.lungfishfastq"))
    }

    // MARK: - Kinds the rule does not apply to

    func testAFrozenFormatDropsNothing() {
        XCTAssertEqual(Self.frozenBundles.count, 4, "alignment, tree, primer scheme and primer analysis")
        let everything = [
            ".lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json",
            ".lungfish-provenance.json.signature.json",
            ".lungfish-provenance.json.pub",
            ".viewstate.json",
            ".genotype-viewstate.json",
            "PROVENANCE.md",
            "provenance/wrapper.json",
        ]
        for bundle in Self.frozenBundles {
            for file in everything {
                XCTAssertFalse(excluded(file, inBundle: bundle), "\(file) in \(bundle)")
            }
        }
    }

    // MARK: - The input

    func testTheKindComesFromTheExtensionIgnoringCase() {
        XCTAssertTrue(excluded(".viewstate.json", inBundle: "GENOME.LUNGFISHREF"))
        XCTAssertTrue(excluded(".genotype-viewstate.json", inBundle: "Result.LungfishGenotype"))
        XCTAssertFalse(excluded(".viewstate.json", inBundle: "GENOME.LUNGFISHMSA"))
    }

    func testAPathWithNoFileNameDropsNothing() {
        for bundle in Self.standardBundles {
            for path in ["", "/", "./", "tracks/"] {
                XCTAssertFalse(excluded(path, inBundle: bundle), "\(path.debugDescription) in \(bundle)")
            }
        }
    }
}
