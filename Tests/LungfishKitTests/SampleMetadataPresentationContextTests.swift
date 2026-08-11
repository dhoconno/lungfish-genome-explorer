// SampleMetadataPresentationContextTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishKit

final class SampleMetadataPresentationContextTests: XCTestCase {
    func testCanonicalIdentityWinsOverAnAliasWithTheSameNormalizedValue() throws {
        let index = try SampleIdentityIndex(samples: [
            .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: ["rg-a"]),
            .init(canonicalID: "sample-b", aliases: [" SAMPLE-A "], alignmentTrackIDs: [], readGroupIDs: ["rg-b"])
        ])

        XCTAssertEqual(index.canonicalSampleID(forMetadataIdentifier: "sample-a"), "sample-a")
        XCTAssertEqual(index.canonicalSampleID(forMetadataIdentifier: " SAMPLE-A "), "sample-a")
    }

    func testAmbiguousAliasesAreRejected() {
        XCTAssertThrowsError(
            try SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: ["donor"], alignmentTrackIDs: [], readGroupIDs: []),
                .init(canonicalID: "sample-b", aliases: ["DONOR"], alignmentTrackIDs: [], readGroupIDs: [])
            ])
        ) { error in
            XCTAssertEqual(error as? SampleIdentityIndexError, .ambiguousAlias("donor"))
        }
    }

    func testAmbiguousTrackAndReadGroupIDsAreRejected() {
        XCTAssertThrowsError(
            try SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: ["track"], readGroupIDs: []),
                .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: ["TRACK"], readGroupIDs: [])
            ])
        ) { error in
            XCTAssertEqual(error as? SampleIdentityIndexError, .ambiguousAlignmentTrackID("track"))
        }
        XCTAssertThrowsError(
            try SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: ["rg"]),
                .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: [], readGroupIDs: ["RG"])
            ])
        ) { error in
            XCTAssertEqual(error as? SampleIdentityIndexError, .ambiguousReadGroupID("rg"))
        }
    }

    func testMultipleReadGroupsResolveToTheirOneCanonicalSample() throws {
        let index = try SampleIdentityIndex(samples: [
            .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: ["track-a"], readGroupIDs: ["rg-1", "rg-2"])
        ])

        XCTAssertEqual(index.canonicalSampleID(forAlignmentTrackID: "track-a"), "sample-a")
        XCTAssertEqual(index.canonicalSampleID(forReadGroupID: "rg-1"), "sample-a")
        XCTAssertEqual(index.canonicalSampleID(forReadGroupID: "rg-2"), "sample-a")
        XCTAssertEqual(index.readGroupIDs(forCanonicalSampleID: "sample-a"), Set(["rg-1", "rg-2"]))
        XCTAssertEqual(index.alignmentTrackIDs(forCanonicalSampleID: "sample-a"), Set(["track-a"]))
        XCTAssertEqual(index.canonicalSampleIDs, Set(["sample-a"]))
    }

    func testExplicitOneSampleFallbackDoesNotRequireAnAlignmentIdentifier() throws {
        let index = try SampleIdentityIndex(
            samples: [.init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: [])],
            explicitOneSampleFallbackCanonicalID: "sample-a"
        )

        XCTAssertEqual(index.canonicalSampleID(forReadGroupID: nil), "sample-a")
        XCTAssertNil(index.canonicalSampleID(forAlignmentTrackID: "inferred-from-file-name"))
    }

    func testMultiSampleFallbackIsRejected() {
        XCTAssertThrowsError(
            try SampleIdentityIndex(
                samples: [
                    .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
                    .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: [], readGroupIDs: [])
                ],
                explicitOneSampleFallbackCanonicalID: "sample-a"
            )
        ) { error in
            XCTAssertEqual(error as? SampleIdentityIndexError, .invalidOneSampleFallback("sample-a"))
        }
    }

    @MainActor
    func testContextImmediatelyDeliversNilStoreThenPreservesAllHeadersOnUpdateAndClear() throws {
        let firstStore = try SampleMetadataStore(
            csvData: Data("sample\tcohort\tsite\nS1\tcase\tA\n".utf8),
            knownSampleIds: ["S1"]
        )
        let context = SampleMetadataPresentationContext(
            finalResultURL: URL(fileURLWithPath: "/results/final/result.lungfish"),
            identityIndex: try SampleIdentityIndex(samples: [
                .init(canonicalID: "S1", aliases: [], alignmentTrackIDs: ["track-1"], readGroupIDs: ["rg-1"])
            ]),
            importContext: .init(
                resultID: "result-1",
                provenanceID: "provenance-1",
                workflowName: "sample-metadata-import",
                workflowVersion: "1.0"
            )
        )
        var deliveredHeaders: [[String]?] = []
        let token = context.observe { store in
            deliveredHeaders.append(store?.columnNames)
        }

        XCTAssertNil(context.sampleMetadataStore)
        XCTAssertEqual(deliveredHeaders, [nil])

        context.updateSampleMetadataStore(firstStore)

        let secondStore = try SampleMetadataStore(
            csvData: Data("sample\tcohort\tsite\tbatch\nS1\tcontrol\tB\t7\n".utf8),
            knownSampleIds: ["S1"]
        )
        context.updateSampleMetadataStore(secondStore)

        XCTAssertEqual(context.sampleMetadataStore?.columnNames, ["cohort", "site", "batch"])
        XCTAssertEqual(deliveredHeaders, [nil, ["cohort", "site"], ["cohort", "site", "batch"]])

        context.clearSampleMetadataStore()
        XCTAssertNil(context.sampleMetadataStore)
        XCTAssertEqual(deliveredHeaders, [nil, ["cohort", "site"], ["cohort", "site", "batch"], nil])

        context.removeObserver(token)
        context.updateSampleMetadataStore(firstStore)
        XCTAssertEqual(deliveredHeaders.count, 4)
    }

    @MainActor
    func testObserverMayRemoveItselfDuringStoreNotification() throws {
        let context = SampleMetadataPresentationContext(
            finalResultURL: URL(fileURLWithPath: "/results/final/result.lungfish"),
            identityIndex: try SampleIdentityIndex(samples: [
                .init(canonicalID: "S1", aliases: [], alignmentTrackIDs: [], readGroupIDs: [])
            ]),
            importContext: .init(
                resultID: "result-1",
                provenanceID: "provenance-1",
                workflowName: "sample-metadata-import",
                workflowVersion: "1.0"
            )
        )
        var callbackCount = 0
        var token: SampleMetadataPresentationContext.ObserverToken?
        token = context.observe { _ in
            callbackCount += 1
            if callbackCount > 1, let token {
                context.removeObserver(token)
            }
        }

        let store = try SampleMetadataStore(
            csvData: Data("sample\tcohort\nS1\tcase\n".utf8),
            knownSampleIds: ["S1"]
        )
        context.updateSampleMetadataStore(store)
        context.updateSampleMetadataStore(store)

        XCTAssertEqual(callbackCount, 2)
    }
}
