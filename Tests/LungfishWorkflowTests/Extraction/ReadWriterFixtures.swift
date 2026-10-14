// ReadWriterFixtures.swift - Shared fixtures of the read writer pins and fault tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest

/// Fixtures shared by the read writer tests of Phase 2.10 lane S31.
enum ReadWriterFixtures {
    /// One four-line record per name, ACGT with quality IIII. Without
    /// `finalLineBreak` the last quality line ends the data.
    static func fastq(_ names: String..., finalLineBreak: Bool = true) -> Data {
        var text = names.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
        if !finalLineBreak { text.removeLast() }
        return Data(text.utf8)
    }

    /// `data` as one gzip member, through the system gzip.
    static func gzip(_ data: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip failed")
        return compressed
    }

    /// The text of a gzip file, read back through the system gzip, so a
    /// multi-member stream is checked by a reader other than ours.
    static func gunzip(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -dc failed for \(url.lastPathComponent)")
        return String(decoding: decoded, as: UTF8.self)
    }

    /// Writes `data` as `name` in `directory` and returns its URL.
    @discardableResult
    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Every name in `directory`, hidden stage files included, sorted.
    static func entries(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    /// The path a descriptor names, or an empty string.
    nonisolated static func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    struct Refusal: Error {}

    /// Counts named events safely across the threads a seam closure can run on.
    final class Tally: Sendable {
        private let counts = Mutex<[String: Int]>([:])

        @discardableResult
        func add(_ key: String) -> Int {
            counts.withLock { counts in
                counts[key, default: 0] += 1
                return counts[key, default: 0]
            }
        }

        subscript(_ key: String) -> Int { counts.withLock { $0[key, default: 0] } }
    }
}
