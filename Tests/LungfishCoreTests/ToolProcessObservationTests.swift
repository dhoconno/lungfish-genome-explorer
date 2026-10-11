// ToolProcessObservationTests.swift - The provenance observer hook of ToolProcess and its environment allowlist
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.7 lane S1 (B1, decision P10). A recorded environment change keeps
/// every changed name, a value only for an allowlisted name, sanitized, and
/// never a PATH value or the value of a name that points at the account's
/// home or scratch folder.
final class ToolProcessEnvironmentChangeAllowlistTests: XCTestCase {
    private static let context = PortablePath.Context(
        projectURL: nil,
        toolRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true),
        storageRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-storage", isDirectory: true),
        temporaryRootURLs: []
    )

    func testOnlyAllowlistedNamesKeepTheirValues() {
        let change = ToolProcessEnvironmentChange(
            base: .inherited,
            set: [
                "MAMBA_NO_BANNER": "1",
                "PATH": "/Users/someone/lungfish-tools/envs/kraken2/bin:/Users/someone/bin:/usr/bin",
                "HOME": "/Users/someone",
                "TMPDIR": "/Users/someone/scratch",
                "MAFFT_TMPDIR": "/Users/someone/scratch/mafft",
                "XDG_CACHE_HOME": "/Users/someone/.cache",
                "DATABASE_URL": "postgres://user:secret@host/db",
                "HTTPS_PROXY": "http://user:secret@proxy:8080",
            ],
            unset: ["PYTHONHOME", "CONDA_PREFIX", "PYTHONHOME"],
            sanitizing: Self.context
        )
        XCTAssertEqual(change.base, .inherited)
        XCTAssertEqual(change.set.map(\.name), [
            "DATABASE_URL", "HOME", "HTTPS_PROXY", "MAFFT_TMPDIR", "MAMBA_NO_BANNER", "PATH", "TMPDIR", "XDG_CACHE_HOME",
        ])
        XCTAssertEqual(change.set.filter { $0.value != nil }, [.init(name: "MAMBA_NO_BANNER", value: "1")])
        XCTAssertEqual(change.unset, ["CONDA_PREFIX", "PYTHONHOME"])
    }

    func testKeptValuesAndPathPrefixEntriesAreSanitized() {
        let change = ToolProcessEnvironmentChange(
            base: .inherited,
            set: [
                "JAVA_HOME": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm",
                "LUNGFISH_STORAGE_ROOT": "/Users/someone/lungfish-storage/databases",
                "MAFFT_BINARIES": "/Users/someone/private/mafft/libexec",
            ],
            pathPrefix: ["/Users/someone/lungfish-tools/envs/bbtools/bin", "/Users/someone/bin", "/usr/bin"],
            sanitizing: Self.context
        )
        XCTAssertEqual(change.set, [
            .init(name: "JAVA_HOME", value: "<tool-root>/envs/bbtools/lib/jvm"),
            .init(name: "LUNGFISH_STORAGE_ROOT", value: "<storage-root>/databases"),
            .init(name: "MAFFT_BINARIES", value: "<external>/libexec"),
        ])
        XCTAssertEqual(change.pathPrefix, ["<tool-root>/envs/bbtools/bin", "<external>/bin", "/usr/bin"])
    }

    /// The four names of decision P10 and PATH never keep a value, and every
    /// name the adapters set for their tools does.
    func testTheAllowlistAndTheNameOnlyListAreDisjoint() {
        let nameOnly = ToolProcessEnvironmentChange.nameOnlyNames
        XCTAssertEqual(nameOnly, ["PATH", "HOME", "TMPDIR", "MAFFT_TMPDIR", "XDG_CACHE_HOME"])
        XCTAssertTrue(ToolProcessEnvironmentChange.valueRecordedNames.isDisjoint(with: nameOnly))
        for name in nameOnly {
            XCTAssertFalse(ToolProcessEnvironmentChange.recordsValue(of: name), name)
        }
        for name in ["MAMBA_ROOT_PREFIX", "JAVA_HOME", "BBMAP_JAVA", "NXF_HOME", "CONDA_PREFIX", "LUNGFISH_CONDA_ROOT"] {
            XCTAssertTrue(ToolProcessEnvironmentChange.recordsValue(of: name), name)
        }
        XCTAssertEqual(ToolProcessEnvironmentChange.valueRecordedNames.count, 21)
    }
}
