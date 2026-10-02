// SafetyNetSupport.swift - Shared helpers for the routing and sidebar-scan safety nets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The safety-net suites freeze today's routing table and sidebar scan so the
// architecture program (review findings R1 and R2) can replace the hand-wired
// tables with registries and see every behaviour change as a test failure.

import Foundation
@testable import LungfishApp

// MARK: - Repository paths

/// Locations of committed fixtures, resolved from this file's path.
enum SafetyNetPaths {
    /// The checkout's `Tests` directory.
    static let testsDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SafetyNets
        .deletingLastPathComponent() // LungfishAppTests
        .deletingLastPathComponent() // Tests

    /// The checkout root.
    static let repositoryRoot: URL = testsDirectory.deletingLastPathComponent()

    /// A path under `Tests/Fixtures`.
    static func fixture(_ relativePath: String) -> URL {
        testsDirectory.appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// A path under `TestData`.
    static func testData(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent("TestData", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// A path under `docs/user-manual/fixtures`, the inputs the demo-project builder copies.
    static func manualFixture(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent("docs/user-manual/fixtures", isDirectory: true)
            .appendingPathComponent(relativePath)
    }
}

// MARK: - Fixture copies

enum SafetyNetFiles {
    enum Failure: Error, CustomStringConvertible {
        case missingFixture(URL)

        var description: String {
            switch self {
            case .missingFixture(let url):
                return "Committed fixture is missing: \(url.path)"
            }
        }
    }

    /// Copies a committed fixture into a scratch location.
    ///
    /// Routes can write caches and sidecars into what they open, so the safety
    /// nets never select a committed fixture in place. A symbolic link (the
    /// primer-scheme fixture is one) is resolved first, so the copy is the real
    /// directory and never a link that dangles once it leaves the repository.
    @discardableResult
    static func copy(_ source: URL, to destination: URL) throws -> URL {
        let resolved = source.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw Failure.missingFixture(source)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: resolved, to: destination)
        return destination
    }

    /// Copies a committed fixture into `directory`, keeping or replacing its name.
    @discardableResult
    static func copy(_ source: URL, into directory: URL, as name: String? = nil) throws -> URL {
        try copy(source, to: directory.appendingPathComponent(name ?? source.lastPathComponent))
    }

    /// Writes UTF-8 text, creating intermediate directories.
    @discardableResult
    static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a directory and its parents.
    @discardableResult
    static func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - SidebarItemType catalog

/// Every `SidebarItemType` case, named the way it is spelled in Swift.
///
/// `SidebarItemType` is not `CaseIterable`, and the safety nets must not change
/// production code to make it so. Two checks keep this catalog complete:
///
/// 1. `caseName(_:)` switches over the enum with no `default`, so a new case
///    stops the test target from compiling until it is named here.
/// 2. `declaredCaseCount` reads how many cases the enum declares from its
///    memory layout, and `RoutingTableSafetyNetTests` compares that with
///    `all.count`, so a case named in the switch but left out of `all` fails.
enum SidebarItemTypeCatalog {
    static let all: [SidebarItemType] = [
        .group, .folder, .sequence, .annotation, .alignment, .coverage, .project,
        .document, .image, .unknown, .referenceBundle, .mhcReferenceBundle,
        .multipleSequenceAlignmentBundle, .phylogeneticTreeBundle, .fastqBundle,
        .primerAnalysisBundle, .primerSchemeBundle, .genotypeResultBundle,
        .twelveSAmpliconResultBundle, .batchGroup, .classificationResult, .esvirituResult,
        .taxTriageResult, .naoMgsResult, .nvdResult, .czIdResult, .analysisResult,
    ]

    static func caseName(_ type: SidebarItemType) -> String {
        switch type {
        case .group: return "group"
        case .folder: return "folder"
        case .sequence: return "sequence"
        case .annotation: return "annotation"
        case .alignment: return "alignment"
        case .coverage: return "coverage"
        case .project: return "project"
        case .document: return "document"
        case .image: return "image"
        case .unknown: return "unknown"
        case .referenceBundle: return "referenceBundle"
        case .mhcReferenceBundle: return "mhcReferenceBundle"
        case .multipleSequenceAlignmentBundle: return "multipleSequenceAlignmentBundle"
        case .phylogeneticTreeBundle: return "phylogeneticTreeBundle"
        case .fastqBundle: return "fastqBundle"
        case .primerAnalysisBundle: return "primerAnalysisBundle"
        case .primerSchemeBundle: return "primerSchemeBundle"
        case .genotypeResultBundle: return "genotypeResultBundle"
        case .twelveSAmpliconResultBundle: return "twelveSAmpliconResultBundle"
        case .batchGroup: return "batchGroup"
        case .classificationResult: return "classificationResult"
        case .esvirituResult: return "esvirituResult"
        case .taxTriageResult: return "taxTriageResult"
        case .naoMgsResult: return "naoMgsResult"
        case .nvdResult: return "nvdResult"
        case .czIdResult: return "czIdResult"
        case .analysisResult: return "analysisResult"
        }
    }

    /// The number of cases `SidebarItemType` declares, or nil when its layout is
    /// not the one-byte tag this check reads.
    ///
    /// A payload-free enum stores its cases as tags 0 to N-1 in declaration
    /// order, and `Optional.none` takes the first unused tag, N. Both rules are
    /// part of Swift's stable ABI on Apple platforms.
    static var declaredCaseCount: Int? {
        guard MemoryLayout<SidebarItemType>.size == 1,
              MemoryLayout<SidebarItemType?>.size == 1 else { return nil }
        let none: SidebarItemType? = nil
        return withUnsafeBytes(of: none) { Int($0[0]) }
    }

    /// The layout tag of one case, used to confirm the tag rule above holds.
    static func layoutTag(of type: SidebarItemType) -> Int {
        withUnsafeBytes(of: type) { Int($0[0]) }
    }
}
