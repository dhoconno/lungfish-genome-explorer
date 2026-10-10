// AnalysisToolRegistryTests.swift - The analysis registry reproduces today's tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnalysisToolRegistryTests: XCTestCase {
    private static let frozenIDs: Set<String> = [
        "bbmap", "bowtie2", "bwa-mem2", "cz-id", "esviritu", "flye", "hifiasm", "kraken2",
        "mafft", "megahit", "minimap2", "naomgs", "nvd", "ont-genotyping", "pbaa",
        "primer-order", "savont", "skesa", "spades", "taxtriage", "viralrecon",
    ]

    // Duplicated from the sidebar pins (SidebarPresentationPinTests), which live in the App tests.
    private static let expectedBadges: [String: String?] = [
        "bbmap": nil, "bowtie2": nil, "bwa-mem2": nil, "cz-id": "CZ", "esviritu": "ES",
        "flye": nil, "hifiasm": nil, "kraken2": "K2", "mafft": nil, "megahit": nil,
        "minimap2": nil, "naomgs": "NM", "nvd": "NVD", "ont-genotyping": nil, "pbaa": nil,
        "primer-order": nil, "savont": nil, "skesa": nil, "spades": nil, "taxtriage": "TT",
        "viralrecon": nil,
    ]

    // A nil symbol means the sidebar falls back to "circle".
    private static let expectedSymbols: [String: String?] = [
        "bbmap": "m.circle", "bowtie2": "m.circle", "bwa-mem2": "m.circle", "cz-id": "c.circle",
        "esviritu": "e.circle", "flye": "s.circle", "hifiasm": "s.circle", "kraken2": "k.circle",
        "mafft": "rectangle.grid.1x2", "megahit": "s.circle", "minimap2": "m.circle",
        "naomgs": "n.circle", "nvd": nil, "ont-genotyping": "tablecells.badge.ellipsis",
        "pbaa": nil, "primer-order": nil, "savont": nil, "skesa": "s.circle",
        "spades": "s.circle", "taxtriage": "t.circle", "viralrecon": "v.circle",
    ]

    func testIDsEqualTheFrozenSet() {
        XCTAssertEqual(Set(AnalysisToolRegistry.all.map { $0.id.rawValue }), Self.frozenIDs)
        XCTAssertEqual(AnalysisToolRegistry.all.count, 21)
    }

    func testIDsAreUnique() {
        let raws = AnalysisToolRegistry.all.map { $0.id.rawValue }
        XCTAssertEqual(raws.count, Set(raws).count)
    }

    func testNoIDPlusHyphenPrefixesAnotherIDPlusHyphen() {
        let prefixes = AnalysisToolRegistry.directoryPrefixes.map(\.single)
        for first in prefixes {
            for second in prefixes where first != second {
                XCTAssertFalse(second.hasPrefix(first), "\(first) prefixes \(second)")
            }
        }
        for entry in AnalysisToolRegistry.directoryPrefixes {
            XCTAssertEqual(entry.single, "\(entry.id.rawValue)-")
            XCTAssertEqual(entry.batch, "\(entry.id.rawValue)-batch-")
        }
    }

    func testDirectoryPrefixesFollowRegistryOrder() {
        XCTAssertEqual(
            AnalysisToolRegistry.directoryPrefixes.map(\.id),
            AnalysisToolRegistry.all.map(\.id))
    }

    func testSixDescriptorsHaveNeitherAManagedToolNorALockedPipeline() {
        var unlinked: Set<String> = []
        for descriptor in AnalysisToolRegistry.all {
            switch descriptor.provisioning {
            case .managedTool, .lockedPipeline: break
            case .container, .importedResult, .builtIn: unlinked.insert(descriptor.id.rawValue)
            }
        }
        XCTAssertEqual(unlinked, ["naomgs", "nvd", "cz-id", "ont-genotyping", "primer-order", "pbaa"])
    }

    func testProvisioningLinksUseLockIDsNotAnalysisIDs() {
        XCTAssertEqual(
            AnalysisToolRegistry.descriptor(for: .bbmap)?.provisioning,
            .managedTool(ManagedToolID(rawValue: "bbtools")))
        XCTAssertEqual(
            AnalysisToolRegistry.descriptor(for: .viralrecon)?.provisioning,
            .lockedPipeline("nf-core-viralrecon"))
        XCTAssertEqual(
            AnalysisToolRegistry.descriptor(for: .taxtriage)?.provisioning,
            .lockedPipeline("taxtriage"))
        XCTAssertEqual(AnalysisToolRegistry.descriptor(for: .pbaa)?.provisioning, .container)
    }

    func testImportedResultIDs() {
        XCTAssertEqual(AnalysisToolRegistry.importedResultIDs, ["naomgs", "nvd", "cz-id"])
    }

    func testDisplayNamesEqualAnalysesFolder() {
        for descriptor in AnalysisToolRegistry.all {
            XCTAssertEqual(
                descriptor.displayName, AnalysesFolder.displayName(for: descriptor.id.rawValue),
                descriptor.id.rawValue)
        }
    }

    func testCapitalizedFallback() {
        XCTAssertEqual(AnalysisToolRegistry.displayName(forRawID: "classification"), "Classification")
        XCTAssertEqual(AnalysisToolRegistry.displayName(forRawID: "foo-bar"), "Foo-Bar")
        XCTAssertEqual(AnalysisToolRegistry.displayName(forRawID: ""), "")
        XCTAssertNil(AnalysisToolRegistry.descriptor(forRawID: "bbtools"))
    }

    func testSymbolsAndBadgesEqualTheSidebarPins() {
        XCTAssertEqual(Set(Self.expectedBadges.keys), Self.frozenIDs)
        XCTAssertEqual(Set(Self.expectedSymbols.keys), Self.frozenIDs)
        for descriptor in AnalysisToolRegistry.all {
            let raw = descriptor.id.rawValue
            XCTAssertEqual(descriptor.sidebarSymbolName, Self.expectedSymbols[raw]!, "symbol of \(raw)")
            XCTAssertEqual(descriptor.classifierBatchBadge, Self.expectedBadges[raw]!, "badge of \(raw)")
        }
    }

    func testIDCodingRoundTrip() throws {
        let data = try JSONEncoder().encode([AnalysisToolID.kraken2, .czId])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"kraken2\",\"cz-id\"]")
        let decoded = try JSONDecoder().decode([AnalysisToolID].self, from: data)
        XCTAssertEqual(decoded, [.kraken2, .czId])
    }

    func testInterpolationUsesRawValue() {
        XCTAssertEqual("\(AnalysisToolID.bwaMem2.rawValue)-batch-", "bwa-mem2-batch-")
        XCTAssertEqual(AnalysisToolID.ontGenotyping.rawValue, "ont-genotyping")
    }

    func testNameParsingFindsEveryKindByPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-parse-\(UUID().uuidString)")
        let analyses = root.appendingPathComponent(AnalysesFolder.directoryName)
        defer { try? FileManager.default.removeItem(at: root) }
        for descriptor in AnalysisToolRegistry.all {
            let raw = descriptor.id.rawValue
            for name in ["\(raw)-2026-03-01T10-20-30", "\(raw)-batch-2026-03-01T10-20-30"] {
                try FileManager.default.createDirectory(
                    at: analyses.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        }
        let found = try AnalysesFolder.listAnalyses(in: root)
        XCTAssertEqual(found.count, 42)
        for info in found {
            XCTAssertTrue(info.url.lastPathComponent.hasPrefix("\(info.tool)-"), info.url.lastPathComponent)
            XCTAssertEqual(info.url.lastPathComponent.contains("-batch-"), info.isBatch)
        }
    }
}
