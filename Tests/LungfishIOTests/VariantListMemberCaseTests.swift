// VariantListMemberCaseTests.swift - An equality on a list-valued INFO key compares each member in its own case
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Lane 13.37, decision MD53 item 1. An equality on an `ANN_`, `CSQ_` or impact key keeps a variant whose
/// comma-joined list holds the value as one member. The member compares byte for byte, as `=` did before the lane,
/// since gene symbols that differ only by case are different genes (Drosophila `w` and `W`).
final class VariantListMemberCaseTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListMemberCase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The headers of `threeRecordVCF` over two records. POS 100 has two ANN entries, the genes `w` then `abc` with the
    /// impacts HIGH then MODERATE. POS 200 has one ANN entry, the gene `W` with the impact MODERATE.
    static let listMemberVCF: String = {
        let headers = StructuredINFOFixture.threeRecordVCF.split(separator: "\n")
            .filter { $0.hasPrefix("#") }.map(String.init)
        let records = [
            "chr1\t100\t.\tC\tT\t50\tPASS\tDP=40;ANN=T|stop_gained|HIGH|w,T|missense_variant|MODERATE|abc\tGT\t0/1",
            "chr1\t200\t.\tA\tG\t50\tPASS\tDP=35;ANN=G|missense_variant|MODERATE|W\tGT\t0/1",
        ]
        return (headers + records).joined(separator: "\n") + "\n"
    }()

    func testEqualityOnAListKeyKeepsOneMemberInItsOwnCaseAtEveryProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                Self.listMemberVCF, profile: profile, in: directory, name: "case")
            for (key, members) in [("ANN_Gene", ["abc", "w"]), ("ANN_IMPACT", ["HIGH", "MODERATE"])] {
                let stored = try StructuredINFOFixture.storedValue(dbURL, position: 100, key: key) ?? ""
                XCTAssertEqual(stored.split(separator: ",").map(String.init).sorted(), members, "\(key) \(profile)")
            }
            let database = try VariantDatabase(url: dbURL)
            func hits(_ key: String, _ value: String) -> [Int] {
                let filter = VariantDatabase.InfoFilter(key: key, op: .eq, value: value)
                return database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            // `w` is one member of `w,abc` and is not `W`.
            XCTAssertEqual(hits("ANN_Gene", "w"), [100], "w \(profile)")
            XCTAssertEqual(hits("ANN_Gene", "W"), [200], "W \(profile)")
            XCTAssertEqual(hits("ANN_Gene", "abc"), [100], "abc \(profile)")
            XCTAssertEqual(hits("ANN_Gene", "ab"), [], "part of a member \(profile)")
            XCTAssertEqual(hits("ann_gene", "w"), [100], "the key compares without case \(profile)")
            // The impact value compares in its own case, so `high` keeps nothing though HIGH is stored.
            XCTAssertEqual(hits("ANN_IMPACT", "HIGH"), [100], "HIGH \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", "high"), [], "high \(profile)")
        }
    }

    /// The headers of `threeRecordVCF` over two records, apart from `listMemberVCF` so the negation test does not move.
    /// POS 100 lists the impacts HIGH,MODERATE and the genes a_c,x. POS 200 lists the impacts HIGH,MODERATE,MODIFIER
    /// and the genes abc,x,x.
    static let commaAndWildcardVCF: String = {
        let headers = StructuredINFOFixture.threeRecordVCF.split(separator: "\n")
            .filter { $0.hasPrefix("#") }.map(String.init)
        let records = [
            "chr1\t100\t.\tC\tT\t50\tPASS\tDP=40;ANN=T|stop_gained|HIGH|a_c,T|missense_variant|MODERATE|x\tGT\t0/1",
            "chr1\t200\t.\tA\tG\t50\tPASS\tDP=35;ANN=G|stop_gained|HIGH|abc,G|missense_variant|MODERATE|x,"
                + "G|upstream_gene_variant|MODIFIER|x\tGT\t0/1",
        ]
        return (headers + records).joined(separator: "\n") + "\n"
    }()

    /// A value that holds a comma is a whole joined list, as the value picker offers it, so `=` and `!=` compare the
    /// whole value and a run of members is no member. A member compares as written, so `_` and `%` are no wildcards.
    func testAValueWithACommaOrAWildcardIsMatchedAsWritten() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                Self.commaAndWildcardVCF, profile: profile, in: directory, name: "comma")
            let database = try VariantDatabase(url: dbURL)
            func hits(_ key: String, _ op: VariantDatabase.InfoFilter.ComparisonOp, _ value: String) -> [Int] {
                let filter = VariantDatabase.InfoFilter(key: key, op: op, value: value)
                return database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            XCTAssertEqual(hits("ANN_IMPACT", .eq, "HIGH,MODERATE"), [100], "= HIGH,MODERATE \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", .neq, "HIGH,MODERATE"), [200], "!= HIGH,MODERATE \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", .eq, "MODERATE,MODIFIER"), [], "= MODERATE,MODIFIER \(profile)")
            XCTAssertEqual(hits("ANN_Gene", .eq, "a_c"), [100], "a_c \(profile)")
            XCTAssertEqual(hits("ANN_Gene", .eq, "abc"), [200], "abc \(profile)")
            XCTAssertEqual(hits("ANN_Gene", .eq, "x"), [100, 200], "x \(profile)")
            for pattern in ["_", "a%", "%"] {
                XCTAssertEqual(hits("ANN_Gene", .eq, pattern), [], "\(pattern) \(profile)")
            }
        }
    }
}
