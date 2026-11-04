// ManagedSamtoolsGate.swift - The skip of a test that imports NAO-MGS on a host with no managed samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
import LungfishIO

/// A NAO-MGS import writes the BAM of each sample with the managed samtools and stops with words when there is none
/// (NAO-IMPORT-BAM-FAILED-SILENT), so a test that runs the whole import needs that samtools on its host. A host
/// without it shows a skip that says so, never a pass. The words of the stop are tested with a stand-in samtools in
/// `NaoMgsImportBamWordsTests`, which needs no managed tool.
public enum ManagedSamtoolsGate {
    /// True when `SamtoolsLocator` finds the managed samtools, the one the NAO-MGS import writes its BAM with.
    public static var isAvailable: Bool { SamtoolsLocator.locate() != nil }

    /// What a skipped test shows.
    public static let skipReason = "No managed samtools on this host, so a NAO-MGS import stops with its samtools words "
        + "and cannot finish. Install the app's tools to run this test."

    /// The Swift Testing trait of a test that imports NAO-MGS, as in `@Test(ManagedSamtoolsGate.enabled)`.
    public static var enabled: ConditionTrait {
        .enabled(if: isAvailable, Comment(rawValue: skipReason))
    }

    /// The XCTest gate of a test that imports NAO-MGS. It skips with ``skipReason`` (a failure under
    /// `LUNGFISH_REQUIRE_TOOLS=1`, as `ToolAvailability` has it).
    public static func requireForXCTest(file: StaticString = #filePath, line: UInt = #line) throws {
        guard isAvailable else {
            try ToolAvailability.skipOrFail(skipReason, file: file, line: line)
        }
    }

    // MARK: - A scratch storage with the host's tools

    /// The host's conda root when the host has the managed samtools, and nil otherwise. Read it before a test moves the
    /// storage root, since the conda root then reads as the scratch one and holds no tools.
    public static func hostCondaRoot() -> String? {
        guard isAvailable else { return nil }
        let store = ManagedStorageConfigStore(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, appIdentity: .current)
        return store.currentCondaRootURL().path
    }

    /// What ``useScratchStorage(_:)`` replaced, to give back to ``restoreRoots(_:)``.
    public struct SavedRoots {
        fileprivate let storage: String?
        fileprivate let conda: String?
    }

    /// Points this process, and so every command it runs in process or starts, at the scratch managed storage
    /// `storage`, and gives it the host's conda root as `LUNGFISH_CONDA_ROOT` when the host has the managed samtools.
    /// Only tools are read from that root, and every write stays under `storage`.
    public static func useScratchStorage(_ storage: URL) -> SavedRoots {
        let environment = ProcessInfo.processInfo.environment
        let saved = SavedRoots(storage: environment["LUNGFISH_STORAGE_ROOT"], conda: environment["LUNGFISH_CONDA_ROOT"])
        if let hostRoot = hostCondaRoot() { setenv("LUNGFISH_CONDA_ROOT", hostRoot, 1) }
        setenv("LUNGFISH_STORAGE_ROOT", storage.path, 1)
        return saved
    }

    /// Gives both roots back as ``useScratchStorage(_:)`` found them.
    public static func restoreRoots(_ saved: SavedRoots) {
        for (key, value) in [("LUNGFISH_STORAGE_ROOT", saved.storage), ("LUNGFISH_CONDA_ROOT", saved.conda)] {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
}
