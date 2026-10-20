// ArchiveToolTestSupport.swift - Crafted tar archives and fake archive tools for the 13.08 tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Writes ustar archives, gzip wrapped with stored blocks, with exact control
/// over entry names and link targets, so tests can build hostile archives that
/// `tar(1)` refuses to create. The zip counterpart is ``TestZipWriter``.
enum TestTarWriter {
    enum Kind {
        case file(Data)
        case directory
        case symlink(target: String)
    }

    struct Entry {
        let name: String
        let kind: Kind

        static func file(_ name: String, _ contents: String) -> Entry {
            Entry(name: name, kind: .file(Data(contents.utf8)))
        }

        static func directory(_ name: String) -> Entry {
            Entry(name: name.hasSuffix("/") ? name : name + "/", kind: .directory)
        }

        static func symlink(_ name: String, to target: String) -> Entry {
            Entry(name: name, kind: .symlink(target: target))
        }
    }

    static func write(_ entries: [Entry], to url: URL, gzip: Bool = true) throws {
        var tar = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, limit: Int) {
                for (index, byte) in Array(text.utf8.prefix(limit)).enumerated() {
                    header[offset + index] = byte
                }
            }
            func putOctal(_ value: Int, at offset: Int, width: Int) {
                let digits = String(value, radix: 8)
                put(String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits, at: offset, limit: width - 1)
            }
            let payload: Data
            let typeflag: UInt8
            let mode: Int
            var linkname = ""
            switch entry.kind {
            case .file(let data):
                payload = data
                typeflag = UInt8(ascii: "0")
                mode = 0o644
            case .directory:
                payload = Data()
                typeflag = UInt8(ascii: "5")
                mode = 0o755
            case .symlink(let target):
                payload = Data()
                typeflag = UInt8(ascii: "2")
                mode = 0o777
                linkname = target
            }
            put(entry.name, at: 0, limit: 100)
            putOctal(mode, at: 100, width: 8)
            putOctal(0, at: 108, width: 8)
            putOctal(0, at: 116, width: 8)
            putOctal(payload.count, at: 124, width: 12)
            putOctal(0, at: 136, width: 12)
            for index in 148..<156 { header[index] = 0x20 }
            header[156] = typeflag
            put(linkname, at: 157, limit: 100)
            put("ustar", at: 257, limit: 5)
            put("00", at: 263, limit: 2)
            let sum = header.reduce(0) { $0 + Int($1) }
            let checksum = String(sum, radix: 8)
            put(String(repeating: "0", count: max(0, 6 - checksum.count)) + checksum, at: 148, limit: 6)
            header[154] = 0
            header[155] = 0x20
            tar.append(contentsOf: header)
            tar.append(payload)
            let remainder = payload.count % 512
            if remainder != 0 { tar.append(Data(repeating: 0, count: 512 - remainder)) }
        }
        tar.append(Data(repeating: 0, count: 1024))
        try (gzip ? gzipStored(tar) : tar).write(to: url)
    }

    static func gzipStored(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        var offset = 0
        repeat {
            let chunk = min(65_535, data.count - offset)
            let length = UInt16(chunk)
            let complement = ~length
            out.append(offset + chunk >= data.count ? 1 : 0)
            out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(complement & 0xFF), UInt8(complement >> 8)])
            out.append(data.subdata(in: offset..<(offset + chunk)))
            offset += chunk
        } while offset < data.count
        let crc = TestZipWriter.crc32(data)
        let size = UInt32(truncatingIfNeeded: data.count)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((crc >> UInt32(shift)) & 0xFF)) }
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((size >> UInt32(shift)) & 0xFF)) }
        return out
    }
}

enum ArchiveToolFixtures {
    /// A shell script that appends its argv to a log, runs `body`, writes
    /// `stderr` to standard error and exits with `exitCode`.
    static func writeFakeTool(
        in directory: URL,
        name: String = "fake-tool",
        exitCode: Int32,
        stderr: String = "",
        body: String = ""
    ) throws -> (tool: URL, argvLog: URL) {
        let tool = directory.appendingPathComponent(name)
        let log = directory.appendingPathComponent("\(name).argv")
        let script = """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\n' "$a"; done; printf -- '--\\n'; } >> '\(log.path)'
        \(body)
        printf '%s' '\(stderr)' >&2
        exit \(exitCode)
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, log)
    }

    /// The argv of every run of a fake tool, one array per run, without argv[0].
    static func recordedArgv(_ log: URL) throws -> [[String]] {
        let text = try String(contentsOf: log, encoding: .utf8)
        var runs: [[String]] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == "--" {
                runs.append(current)
                current = []
            } else {
                current.append(String(line))
            }
        }
        return runs
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else {
                throw NSError(domain: "ArchiveToolFixtures", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(url.lastPathComponent) never appeared",
                ])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
