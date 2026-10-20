// GzipPinSupport.swift - Fixtures and a child counter for the gzip reader pins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Phase 2.13 lane 13.06. Writes gzip fixtures with the system gzip, as the readers decompress them, and counts the
/// `gzip -dc` children that a reader left behind.
enum GzipPinSupport {
    /// Writes `bytes` to `directory/name` and gzips them in place, so the result is `directory/name.gz`.
    static func gzip(_ bytes: [UInt8], in directory: URL, named name: String) throws -> URL {
        let plain = directory.appendingPathComponent(name)
        try Data(bytes).write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", plain.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "gzip failed on the fixture")
        return plain.appendingPathExtension("gz")
    }

    static func gzip(_ text: String, in directory: URL, named name: String) throws -> URL {
        try gzip(Array(text.utf8), in: directory, named: name)
    }

    /// The file `gzipURL` with its last `count` bytes removed, so gzip meets the end of the file inside its stream.
    static func truncated(_ gzipURL: URL, removing count: Int, as name: String) throws -> URL {
        let bytes = try Data(contentsOf: gzipURL)
        let cut = gzipURL.deletingLastPathComponent().appendingPathComponent(name)
        try bytes.prefix(bytes.count - count).write(to: cut)
        return cut
    }

    /// How many `gzip -dc <url>` processes are alive now. The path is unique per test, so no other test counts here.
    static func gzipChildCount(for url: URL) -> Int {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "gzip -dc \(url.path)"]
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return -1 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).count
    }
}
