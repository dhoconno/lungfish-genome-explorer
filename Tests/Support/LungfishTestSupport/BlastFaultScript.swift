// BlastFaultScript.swift - What one Put of a search does on the BLAST fault stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What one Put of a search does on ``BlastFaultStandIn``, the first send or a copy.
///
/// Each fault of ARCH-BLAST-RESILIENCE section 7 is one value here. A script runs in the order a real search does.
/// Its ``put`` faults answer POSTs until they run out, and the next POST is accepted with this script's RID. Its
/// ``status`` faults then answer status checks until they run out, and ``search`` answers from there on. Its
/// ``result`` faults answer fetches until they run out, and ``body`` answers from there on.
public struct BlastFaultScript: Sendable {
    /// What NCBI does with a search it accepted. Seconds count from the Put on the stand-in's clock.
    public enum Search: Sendable, Equatable {
        /// READY at the first check.
        case readyAtOnce
        /// WAITING until this many seconds after the Put, then READY, for a search that is late by 90 s or by hours.
        case ready(after: TimeInterval)
        /// WAITING until a test calls ``BlastFaultStandIn/release(rid:)``. A test holds a search by not calling it.
        case held
        /// WAITING, then `Status=UNKNOWN` from this many seconds after the Put on, as NCBI answers for an expired RID.
        case unknown(after: TimeInterval)
        /// `Status=FAILED` with NCBI's words on the page.
        case failed(words: String)
    }

    /// One POST that does not start a search.
    public enum PutFault: Sendable, Equatable {
        /// This HTTP status, as NCBI answers when it is busy.
        case http(status: Int)
        /// A 200 page with no RID on it, holding these words.
        case noRID(page: String)
        /// The whole Put is read and the connection closes with no answer, so the client cannot know what happened.
        case droppedAfterSending
    }

    /// One status check that gets something other than the search's own answer.
    public enum StatusFault: Sendable, Equatable {
        /// This HTTP status.
        case http(status: Int)
        /// A 200 page with no Status line.
        case noStatusLine
        /// A 200 page with nothing on it.
        case emptyPage
        /// `Status=UNKNOWN`, for an early UNKNOWN that is followed by the search's own answer.
        case unknown
        /// The connection closes with no answer.
        case dropped
    }

    /// One result fetch that gets something other than the search's result.
    public enum ResultFault: Sendable, Equatable {
        /// This HTTP status.
        case http(status: Int)
        /// A 200 HTML page in place of the result.
        case html
        /// A 200 answer with nothing in it.
        case empty
        /// A 200 answer that starts as a ZIP archive and cannot be unpacked.
        case damagedZip
        /// The connection closes with no answer.
        case dropped
    }

    /// A JSON2 result with two queries and no hits, for the two reads the BLAST stand-in tests send.
    public static let noHitsResult = Data("""
    {"BlastOutput2": [\
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_1", "query_len": 10, "hits": []}}}}, \
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_2", "query_len": 10, "hits": []}}}}]}
    """.utf8)

    /// Bytes that begin as a ZIP archive and end before any entry is whole.
    public static let damagedZip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF])

    public var put: [PutFault]
    public var search: Search
    public var status: [StatusFault]
    public var result: [ResultFault]
    /// What the accepted Put gives as RTOE.
    public var rtoe: Int
    /// What a READY reply says as `ThereAreHits`, with no such line when nil.
    public var thereAreHits: Bool?
    /// The result this Put's search ends in. Two Puts can hold different tied records.
    public var body: Data

    public init(
        put: [PutFault] = [],
        search: Search = .readyAtOnce,
        status: [StatusFault] = [],
        result: [ResultFault] = [],
        rtoe: Int = 1,
        thereAreHits: Bool? = false,
        body: Data = BlastFaultScript.noHitsResult
    ) {
        self.put = put
        self.search = search
        self.status = status
        self.result = result
        self.rtoe = rtoe
        self.thereAreHits = thereAreHits
        self.body = body
    }
}
