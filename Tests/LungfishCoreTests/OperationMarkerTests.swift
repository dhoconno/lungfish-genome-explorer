// OperationMarkerTests.swift — Tests for shared in-progress directory marker
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishCore

struct OperationMarkerTests {

    @Test
    func isInProgressReturnsFalseForUnmarkedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func markAndClearRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        OperationMarker.markInProgress(dir, detail: "Importing…")
        #expect(OperationMarker.isInProgress(dir))

        OperationMarker.clearInProgress(dir)
        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func clearInProgressIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        OperationMarker.clearInProgress(dir)
        OperationMarker.clearInProgress(dir)
        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func markerFileUsesProcessingFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        OperationMarker.markInProgress(dir, detail: "Test detail")

        let markerURL = dir.appendingPathComponent(".processing")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        let content = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(content == "Test detail")
    }
}
