// FileTypeUtilityBundleKindTests.swift - The category FileTypeUtility gives each Lungfish folder kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Pins what `FileTypeUtility` answers for the Lungfish folder kinds. The answers come from
/// `BundleKindRegistry` (Phase 2.6, lane B7), and the `fileType.detect` rows of `BundleKindParityTests` in the
/// App tests freeze the same answers. These tests run in the IO target alone, so a registry edit that moves
/// a category fails here first.
final class FileTypeUtilityBundleKindTests: XCTestCase {
    /// The two kinds `FileTypeUtility` calls a reference bundle. The FASTQ bundle is the only other kind it names.
    private static let referenceKinds: [BundleKindID] = [.reference, .mhcReference]

    private func folderExtension(of kind: BundleKindID, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(
            BundleKindRegistry.descriptor(for: kind)?.folderExtensions.first,
            "No folder extension for \(kind)", file: file, line: line
        )
    }

    /// The answer for a folder spelled `name`, asked by URL as the import log and the sidebar's file rows do.
    private func detect(_ name: String) -> FileTypeUtility.FileTypeInfo {
        FileTypeUtility.detect(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testGenomeAndMHCReferencesAreReferenceBundlesInEverySpelling() throws {
        for kind in Self.referenceKinds {
            let ext = try folderExtension(of: kind)
            for spelling in [ext, ext.uppercased()] {
                let info = detect("Example.\(spelling)")
                XCTAssertEqual(info.category, .referenceBundle, "\(kind) as .\(spelling)")
                XCTAssertEqual(info.iconName, "cylinder.split.1x2", "\(kind) as .\(spelling)")
                XCTAssertFalse(info.supportsQuickLook, "\(kind) as .\(spelling)")
                XCTAssertTrue(info.isGenomicsFormat, "\(kind) as .\(spelling)")
            }
            XCTAssertEqual(FileTypeUtility.detect(extension: ext).category, .referenceBundle, "\(kind) by extension")
            XCTAssertTrue(FileTypeUtility.isKnownExtension(ext), "\(kind) is a known extension")
            XCTAssertTrue(FileTypeUtility.allKnownExtensions.contains(ext), "\(kind) is listed")
        }
    }

    func testFASTQBundleIsASequenceInEverySpelling() throws {
        let ext = try folderExtension(of: .fastq)
        for spelling in [ext, ext.uppercased()] {
            let info = detect("Reads.\(spelling)")
            XCTAssertEqual(info.category, .sequence, ".\(spelling)")
            XCTAssertEqual(info.iconName, "doc.text", ".\(spelling)")
            XCTAssertFalse(info.supportsQuickLook, ".\(spelling)")
        }
        XCTAssertEqual(FileTypeUtility.detect(extension: ext).category, .sequence)
        XCTAssertTrue(FileTypeUtility.isKnownExtension(ext))
    }

    /// The 12S reference database is its own kind and not a genome reference (plan row S10). FileTypeUtility
    /// listed it as a reference bundle, so `ImportService.detectFormat` returned it as a genomics format.
    func testTwelveSReferenceIsItsOwnKindAndNotAGenomeReferenceBundle() throws {
        let ext = try folderExtension(of: .twelveSReference)
        for spelling in [ext, ext.uppercased()] {
            XCTAssertNotEqual(
                detect("Example.\(spelling)").category, .referenceBundle,
                "A .\(spelling) folder is not a genome reference bundle"
            )
        }
        XCTAssertNotEqual(FileTypeUtility.detect(extension: ext).category, .referenceBundle)
        XCTAssertFalse(FileTypeUtility.allKnownExtensions.contains(ext), "\(ext) names no category of its own")
    }

    /// The project, the alignment, the tree, both primer kinds, the genotype and 12S results, the 12S
    /// reference database, the CZ ID import, a run bundle and both workflow kinds have no category of their own.
    func testEveryOtherKindIsUnknownAndOffersQuickLook() throws {
        let named: Set<BundleKindID> = Set(Self.referenceKinds + [.fastq])
        var checked = 0
        for descriptor in BundleKindRegistry.all where !named.contains(descriptor.id) {
            let ext = try folderExtension(of: descriptor.id)
            for spelling in [ext, ext.uppercased()] {
                let info = detect("Example.\(spelling)")
                XCTAssertEqual(info.category, .unknown, "\(descriptor.id) as .\(spelling)")
                XCTAssertEqual(info.iconName, "doc.questionmark", "\(descriptor.id) as .\(spelling)")
                XCTAssertTrue(info.supportsQuickLook, "\(descriptor.id) as .\(spelling)")
                XCTAssertFalse(info.isGenomicsFormat, "\(descriptor.id) as .\(spelling)")
            }
            XCTAssertFalse(FileTypeUtility.isKnownExtension(ext), "\(descriptor.id) is not a known extension")
            checked += 1
        }
        XCTAssertEqual(checked, 12, "15 kinds, less the 3 named kinds")
    }
}
