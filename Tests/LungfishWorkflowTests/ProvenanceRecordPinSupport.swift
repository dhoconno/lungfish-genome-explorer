// ProvenanceRecordPinSupport.swift - Byte pins for the records that Phase 2.13 lane 13.13 moves onto the writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// The fixed bytes of rows 10 and 11 of `BIO-13.12.md` F2 (the exporter's `provenance.json` and container manifest) and
/// the plain-encoder form of the four sites of A-F5 in `ARCH-13.13-QA3.md`.
///
/// The files in `Tests/Fixtures/provenance-record-pins` were taken at the base `bd0893b02` with
/// `LUNGFISH_CAPTURE_RECORD_PINS=1`, before any encode moved. A file that exists is never written again.
enum ProvenanceRecordPin {
    static var folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/provenance-record-pins", isDirectory: true)
    }

    static func assertBytes(
        _ data: Data,
        equalFixture name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = folder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_RECORD_PINS"] == "1",
           !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(
            data,
            expected,
            "\(name) moved. It now reads:\n\(String(decoding: data, as: UTF8.self))",
            file: file,
            line: line
        )
    }

    /// The bytes the four plain-encoder sites wrote at the base. A plain `JSONEncoder` set to `.prettyPrinted` and
    /// `.sortedKeys` with ISO 8601 dates, which escapes every slash.
    static func plainEncoderBytes(of envelope: ProvenanceEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Pins a record to the bytes of the plain encoder, with its slashes escaped, which the four plain-encoder sites
    /// wrote before lane 13.13 moved them onto the writer (item 4 of the ARCH ruling). Each site's test now asserts
    /// `assertWriterBytes`, and `testThePlainEncoderAndTheWriterDifferOnlyInSlashes` keeps this form as the proof of
    /// the prediction in `SCR/lanes/13.13/predictions.md`.
    static func assertPlainEncoderBytes(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(data)
        XCTAssertEqual(
            data,
            try plainEncoderBytes(of: envelope),
            "The record is no longer the plain encoder's bytes.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            hasEscapedSlash(String(decoding: data, as: UTF8.self)),
            "The record holds no escaped slash.",
            file: file,
            line: line
        )
    }

    /// Whether `json` holds a `\/` escape. A backslash starts an escape, so the second backslash of `\\` ends it. A
    /// string value that holds a backslash before a slash is not one, and the capabilities text that the primer
    /// inspection record embeds is such a value, since `JSONSerialization` escapes the slashes of its own text.
    static func hasEscapedSlash(_ json: String) -> Bool {
        var escaping = false
        for character in json {
            if escaping {
                if character == "/" { return true }
                escaping = false
            } else if character == "\\" {
                escaping = true
            }
        }
        return false
    }

    /// Pins a record of the four sites to the writer's bytes, with its slashes as typed.
    static func assertWriterBytes(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(data)
        XCTAssertEqual(
            data,
            try ProvenanceWriter.package(envelope),
            "The record is no longer the writer's bytes.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            hasEscapedSlash(String(decoding: data, as: UTF8.self)),
            "The record holds an escaped slash.",
            file: file,
            line: line
        )
    }
}
