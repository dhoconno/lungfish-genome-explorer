// DownloadedBundleSnapshotRenderTests.swift - How the bundle snapshot prints a record's option values
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, grant 4. A record's option can hold a dictionary (the `fetchedRecord` entry of
// a live snapshot names its status and the date of the fetch). A `Dictionary` iterates in another
// order in each process and the entry holds the day of the run, so the snapshot of a bundle prints a
// dictionary with its keys in sorted order, an array with its values in sorted order, and an ISO 8601
// date inside either as `<date>`. Every other value prints as it did before, so the pin snapshots of
// lane A44 are unchanged.

import XCTest
import LungfishWorkflow

final class DownloadedBundleSnapshotRenderTests: XCTestCase {
    func testADictionaryPrintsItsKeysInSortedOrder() {
        let entry: ParameterValue = .dictionary([
            "status": .string("liveSnapshot"),
            "listingFiles": .array([.file(URL(fileURLWithPath: "/staging/sources/record.gb"))]),
            "fetchedAt": .string("2026-10-14T12:34:56Z"),
            "path": .file(URL(fileURLWithPath: "/staging/db")),
        ])
        XCTAssertEqual(
            DownloadedBundleSnapshot.render(entry),
            #"{fetchedAt="<date>", listingFiles=[file:/staging/sources/record.gb], path=file:/staging/db, status="liveSnapshot"}"#)
    }

    func testAnArrayPrintsItsValuesInSortedOrder() {
        let list: ParameterValue = .array([.string("b"), .string("c"), .string("a")])
        XCTAssertEqual(DownloadedBundleSnapshot.render(list), #"["a", "b", "c"]"#)
    }

    func testANestedValuePrintsInSortedOrderAtEveryLevel() {
        let nested: ParameterValue = .dictionary([
            "outer": .dictionary(["z": .integer(1), "a": .boolean(true)]),
            "list": .array([.integer(2), .integer(10), .number(1.5)]),
            "none": .null,
        ])
        XCTAssertEqual(
            DownloadedBundleSnapshot.render(nested),
            "{list=[1.5, 10, 2], none=null, outer={a=true, z=1}}")
    }

    func testAnISO8601DateInsideADictionaryOrAnArrayIsMasked() {
        let dates = [
            "2026-10-14T12:34:56Z", "2026-10-14T12:34:56.789Z", "2026-10-14T12:34:56+02:00", "2026-10-14T12:34:56-0500",
        ]
        for date in dates {
            XCTAssertEqual(
                DownloadedBundleSnapshot.render(.dictionary(["at": .string(date)])), #"{at="<date>"}"#, date)
            XCTAssertEqual(DownloadedBundleSnapshot.render(.array([.string(date)])), #"["<date>"]"#, date)
        }
        XCTAssertEqual(
            DownloadedBundleSnapshot.render(.dictionary(["note": .string("fetched 2026-10-14T12:34:56Z by lungfish")])),
            #"{note="fetched <date> by lungfish"}"#)
        XCTAssertEqual(
            DownloadedBundleSnapshot.render(.dictionary(["day": .string("2026-10-14")])), #"{day="2026-10-14"}"#,
            "a date with no time of day names no run")
    }

    /// The pin snapshots of lane A44 hold none of these values as a dictionary or array, and must not move.
    func testEveryOtherValuePrintsAsItDidBefore() {
        XCTAssertEqual(DownloadedBundleSnapshot.render(nil), "-")
        XCTAssertEqual(DownloadedBundleSnapshot.render(.string("a\nb")), #""a\nb""#)
        XCTAssertEqual(DownloadedBundleSnapshot.render(.integer(7)), "7")
        XCTAssertEqual(DownloadedBundleSnapshot.render(.number(2.5)), "2.5")
        XCTAssertEqual(DownloadedBundleSnapshot.render(.boolean(false)), "false")
        XCTAssertEqual(DownloadedBundleSnapshot.render(.null), "null")
        XCTAssertEqual(DownloadedBundleSnapshot.render(.file(URL(fileURLWithPath: "/a/b"))), "file:/a/b")
        XCTAssertEqual(
            DownloadedBundleSnapshot.render(.string("2026-10-14T12:34:56Z")), #""2026-10-14T12:34:56Z""#,
            "a top-level string keeps its date, as the pins of lane A44 print it")
    }
}
