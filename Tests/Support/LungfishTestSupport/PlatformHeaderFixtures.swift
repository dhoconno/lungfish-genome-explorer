// PlatformHeaderFixtures.swift - Paths of the Tests/Fixtures/platform-headers reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The small read files in `Tests/Fixtures/platform-headers`, one per header
/// form the platform detector knows. Real header forms with synthetic bases.
/// `Tests/Fixtures/platform-headers/README.md` names the source of each form.
public enum PlatformHeaderFixtures {

    /// `Tests/Fixtures/platform-headers`, resolved from this source file.
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LungfishTestSupport/
            .deletingLastPathComponent()   // Support/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures/platform-headers", isDirectory: true)
    }

    /// The fixture file with the given name, such as `ont-dorado-samtags-tab.fastq`.
    public static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Copies a fixture into `directory` under `name` (or its own name) and returns the copy.
    @discardableResult
    public static func copy(_ name: String, to directory: URL, as newName: String? = nil) throws -> URL {
        let destination = directory.appendingPathComponent(newName ?? name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url(name), to: destination)
        return destination
    }
}
