// GzipPinSupport.swift - Byte-level helpers for the gzip stream site pins of Phase 2.13 lane 13.07
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import XCTest

enum GzipPinError: Error {
    case notGzip
    case toolFailed(String)
}

/// The fields of the first member header of a gzip stream (RFC 1952).
struct GzipMemberHeader: Equatable {
    let flags: UInt8
    let modificationTime: UInt32
    let extraFlags: UInt8
    let operatingSystem: UInt8
    /// The stored file name, nil when the name flag is clear.
    let name: String?

    init(_ data: Data) throws {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw GzipPinError.notGzip
        }
        flags = bytes[3]
        modificationTime = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << UInt32(8 * $1) }
        extraFlags = bytes[8]
        operatingSystem = bytes[9]
        if flags & 0x08 != 0 {
            guard let end = bytes[10...].firstIndex(of: 0) else { throw GzipPinError.notGzip }
            name = String(decoding: bytes[10..<end], as: UTF8.self)
        } else {
            name = nil
        }
    }
}

/// Runs the system gzip and compares gzip members byte for byte with what it writes.
///
/// `gzip -c <file>` stores the file's name and modification time in the member header and `gzip -n`
/// does not, and a stream on standard input carries the clock time. The checks below rebuild the
/// reference member from those header fields, so the whole member is compared, header included.
enum GzipPin {
    /// Runs `/usr/bin/gzip` with `arguments` and `stdin`, returning its standard output.
    static func gzip(_ arguments: [String], stdin: Data? = nil) throws -> Data {
        let result = try ToolProcess.runBlocking(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            stdin: stdin.map { ToolProcessInput.data($0) } ?? ToolProcessInput.null,
            label: "gzip"
        ))
        guard result.isSuccess else { throw GzipPinError.toolFailed(result.stderrText) }
        return result.stdout
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `data` with the four modification time bytes of its gzip header cleared.
    static func clearingModificationTime(_ data: Data) -> Data {
        var bytes = data
        for offset in 4..<8 where offset < bytes.count {
            bytes[bytes.startIndex + offset] = 0
        }
        return bytes
    }

    /// Asserts `compressed` is exactly what `/usr/bin/gzip <flags> -c <file>` writes for the same bytes in a
    /// file with the name and modification time its header records, and returns the header and the bytes.
    @discardableResult
    static func assertGzipOfNamedFile(
        _ compressed: Data,
        flags: [String],
        scratch: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (header: GzipMemberHeader, raw: Data) {
        let header = try GzipMemberHeader(compressed)
        let raw = try gzip(["-dc"], stdin: compressed)
        let folder = scratch.appendingPathComponent("gzip-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent(header.name ?? "reference.fastq")
        try raw.write(to: input)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(header.modificationTime))],
            ofItemAtPath: input.path
        )
        let reference = try gzip(flags + ["-c", input.path])
        XCTAssertEqual(
            sha256Hex(compressed), sha256Hex(reference),
            "the member must be what gzip \(flags) -c writes for \(input.lastPathComponent)",
            file: file, line: line
        )
        return (header, raw)
    }

    /// Asserts `compressed` is what `/usr/bin/gzip -c` writes for the same bytes on standard input, apart
    /// from the four clock time bytes of the header.
    @discardableResult
    static func assertGzipOfStandardInput(
        _ compressed: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (header: GzipMemberHeader, raw: Data) {
        let header = try GzipMemberHeader(compressed)
        let raw = try gzip(["-dc"], stdin: compressed)
        let reference = try gzip(["-c"], stdin: raw)
        XCTAssertEqual(
            sha256Hex(clearingModificationTime(compressed)),
            sha256Hex(clearingModificationTime(reference)),
            "the member must be what gzip -c writes for standard input",
            file: file, line: line
        )
        return (header, raw)
    }

    /// The command line of every running process, one per line.
    static func processCommands() throws -> String {
        let result = try ToolProcess.runBlocking(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "command="],
            environment: ["PATH": "/usr/bin:/bin"],
            label: "ps"
        ))
        return result.stdoutText
    }
}
