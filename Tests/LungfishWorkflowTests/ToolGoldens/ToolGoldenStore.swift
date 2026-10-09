// ToolGoldenStore.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reads, writes and compares the per-case golden folders under
// Tests/Fixtures/golden/tools. Capture mode (LUNGFISH_CAPTURE_TOOL_GOLDENS=1)
// runs a case twice, refuses to write unless both runs agree, then replaces
// the case's folder. Compare mode runs once and diffs against the folder.

import CryptoKit
import Foundation

enum ToolGoldenStore {
    static var isCaptureMode: Bool {
        ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_TOOL_GOLDENS"] == "1"
    }

    static var root: URL {
        ToolGoldenHarness.fixturesRoot.appendingPathComponent("golden/tools", isDirectory: true)
    }

    static func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every file under a case folder, keyed by its relative path.
    static func read(id: String) throws -> [String: Data]? {
        let base = folder(for: id)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }

    static func write(id: String, files: [String: Data]) throws {
        let base = folder(for: id)
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
        for (relative, data) in files {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }

    /// Case folders on disk, so a case removed from the table cannot leave a stale golden.
    static func capturedCaseIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }.sorted()
    }

    /// A readable report of every difference between two golden file sets,
    /// with a unified diff for each changed text file. Empty when they match.
    static func differences(expected: [String: Data], actual: [String: Data], expectedLabel: String, actualLabel: String) -> String {
        var report: [String] = []
        for name in Set(expected.keys).union(actual.keys).sorted() {
            switch (expected[name], actual[name]) {
            case (nil, .some):
                report.append("+ \(name): produced but has no golden")
            case (.some, nil):
                report.append("- \(name): golden not produced")
            case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                report.append("~ \(name):\n" + unifiedDiff(lhs, rhs, name: name, expectedLabel: expectedLabel, actualLabel: actualLabel))
            default:
                break
            }
        }
        return report.joined(separator: "\n")
    }

    static func unifiedDiff(_ lhs: Data, _ rhs: Data, name: String, expectedLabel: String, actualLabel: String) -> String {
        guard !lhs.contains(0), !rhs.contains(0),
              String(data: lhs, encoding: .utf8) != nil, String(data: rhs, encoding: .utf8) != nil
        else {
            return "binary files differ: \(lhs.count) bytes sha256 \(sha256Hex(lhs)) vs \(rhs.count) bytes sha256 \(sha256Hex(rhs))"
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-tool-golden-diff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let left = directory.appendingPathComponent("expected")
            let right = directory.appendingPathComponent("actual")
            try lhs.write(to: left)
            try rhs.write(to: right)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            process.arguments = [
                "-u", "--label", "\(expectedLabel)/\(name)", "--label", "\(actualLabel)/\(name)",
                left.path, right.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 200 {
                return lines.prefix(200).joined(separator: "\n") + "\n... (\(lines.count - 200) more diff lines)"
            }
            return lines.joined(separator: "\n")
        } catch {
            return "could not diff \(name): \(error)"
        }
    }
}
