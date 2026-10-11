// FileTypeUtilityBundleKindTests.swift - The category FileTypeUtility gives each Lungfish folder kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Pins what `FileTypeUtility` answers for the Lungfish folder kinds. The answers come from
/// `BundleKindRegistry` (Phase 2.6, lane B7), and `BundleKindParityTests` in the App tests freezes the
/// same answers through the sidebar and the import log. These tests run in the IO target alone, so a
/// registry edit that moves a category fails here first.
final class FileTypeUtilityBundleKindTests: XCTestCase {
    /// The kinds `FileTypeUtility` gives a category of their own. Every other kind is unknown to it.
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

    /// The project, the alignment, the tree, both primer kinds, the genotype and 12S results, the CZ ID
    /// import, a run bundle and both workflow kinds have no category of their own. The 12S reference
    /// database is left out until the commit that settles its answer (plan row S10).
    func testEveryOtherKindIsUnknownAndOffersQuickLook() throws {
        let named: Set<BundleKindID> = Set(Self.referenceKinds + [.fastq, .twelveSReference])
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
        XCTAssertEqual(checked, 11, "15 kinds, less the 3 named kinds and the 12S reference")
    }
}
