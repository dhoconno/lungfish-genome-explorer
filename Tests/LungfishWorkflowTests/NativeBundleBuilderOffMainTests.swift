// NativeBundleBuilderOffMainTests.swift - Characterization tests for F17
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Characterizes NativeBundleBuilder.build() when driven entirely from a
// background (non-MainActor) context. Before F17, NativeBundleBuilder was
// @MainActor, which forced every construction and build() call onto the
// main actor even from CLI/background callers. This test class is
// deliberately NOT @MainActor: if NativeBundleBuilder regresses to
// requiring MainActor isolation, constructing/awaiting it here from a
// background actor would force an implicit hop, which we assert against
// by running the whole build on a background actor and diffing output
// against a MainActor-driven build of the identical configuration.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// A plain background actor with no relationship to the main actor, used to
/// prove NativeBundleBuilder.build() can run to completion without ever
/// touching MainActor.
private actor BackgroundBuildRunner {
    func build(
        configuration: BuildConfiguration,
        toolsHome: URL
    ) async throws -> URL {
        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: toolsHome)
        )
        return try await builder.build(configuration: configuration)
    }
}

final class NativeBundleBuilderOffMainTests: XCTestCase {

    private func writeFakeManagedTool(
        home: URL,
        environment: String,
        executable: String,
        script: String
    ) throws {
        let binDir = home
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let toolURL = binDir.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    private func makeFixtureRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    private func writeFakeSamtools(home: URL, faidxLine: String) throws {
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "\(faidxLine)\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)
    }

    /// Builds an identical bundle twice from the same source fixture: once
    /// driven from a background actor with no MainActor involvement, once
    /// driven from the main actor (mirroring the existing MainActor-annotated
    /// provenance test suite). Every produced file byte-for-byte matches,
    /// except run-specific identifiers (staging UUIDs are not part of the
    /// published tree, and provenance run IDs/timestamps are excluded from
    /// this comparison by construction: we diff file trees, not the
    /// provenance envelope's own UUIDs/timestamps aren't present in outputs
    /// we compare).
    func testBuildProducesIdenticalBundleOffMainAndOnMain() async throws {
        let root = try makeFixtureRoot()
        let fastaContent = ">chr1\nACGTACGTACGTACGTACGT\n>chr2\nTTGGCCAATTGGCCAATTGG\n"

        // --- Off-main build ---
        let offMainRoot = root.appendingPathComponent("off-main", isDirectory: true)
        try FileManager.default.createDirectory(at: offMainRoot, withIntermediateDirectories: true)
        let offMainFasta = offMainRoot.appendingPathComponent("source.fa")
        try fastaContent.write(to: offMainFasta, atomically: true, encoding: .utf8)
        let offMainHome = offMainRoot.appendingPathComponent("home", isDirectory: true)
        try writeFakeSamtools(home: offMainHome, faidxLine: "chr1\\t20\\t6\\t20\\t21\\nchr2\\t20\\t33\\t20\\t21")

        let offMainConfiguration = BuildConfiguration(
            name: "OffMain Bundle",
            identifier: "org.lungfish.test.offmain",
            fastaURL: offMainFasta,
            outputDirectory: offMainRoot,
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            compressFASTA: false
        )

        let runner = BackgroundBuildRunner()
        let offMainBundleURL = try await runner.build(
            configuration: offMainConfiguration,
            toolsHome: offMainHome
        )

        // --- On-main build (reference behavior) ---
        let onMainRoot = root.appendingPathComponent("on-main", isDirectory: true)
        try FileManager.default.createDirectory(at: onMainRoot, withIntermediateDirectories: true)
        let onMainFasta = onMainRoot.appendingPathComponent("source.fa")
        try fastaContent.write(to: onMainFasta, atomically: true, encoding: .utf8)
        let onMainHome = onMainRoot.appendingPathComponent("home", isDirectory: true)
        try writeFakeSamtools(home: onMainHome, faidxLine: "chr1\\t20\\t6\\t20\\t21\\nchr2\\t20\\t33\\t20\\t21")

        let onMainConfiguration = BuildConfiguration(
            name: "OnMain Bundle",
            identifier: "org.lungfish.test.onmain",
            fastaURL: onMainFasta,
            outputDirectory: onMainRoot,
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            compressFASTA: false
        )
        let onMainBundleURL = try await MainActorBuildRunner.build(
            configuration: onMainConfiguration,
            toolsHome: onMainHome
        )

        // --- Compare the two bundles structurally and byte-for-byte ---
        try assertBundlesMatch(offMainBundleURL, onMainBundleURL)
    }

    /// Diffs two built bundle trees for structural + content equivalence,
    /// ignoring the manifest fields and provenance envelope fields that are
    /// legitimately run-specific (bundle name/identifier baked from the
    /// differing configuration names, and provenance run UUIDs/timestamps).
    private func assertBundlesMatch(_ lhs: URL, _ rhs: URL) throws {
        let fm = FileManager.default
        func relativeFiles(under root: URL) throws -> [String] {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [] }
            var paths: [String] = []
            let rootPath = root.standardizedFileURL.path
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let standardized = fileURL.standardizedFileURL.path
                XCTAssertTrue(standardized.hasPrefix(rootPath + "/"))
                paths.append(String(standardized.dropFirst(rootPath.count + 1)))
            }
            return paths.sorted()
        }

        let lhsFiles = try relativeFiles(under: lhs)
        let rhsFiles = try relativeFiles(under: rhs)
        XCTAssertEqual(lhsFiles, rhsFiles, "Off-main and on-main builds produced different file trees")

        // Files whose bytes legitimately differ per run (identifiers, paths
        // baked from the distinct configuration names used for the two
        // builds, timestamps, wall-time measurements). This covers both the
        // top-level manifest/provenance envelope and the per-output
        // "<name>.lungfish-provenance.json" sidecars ProvenanceRecorder
        // writes into "provenance/" alongside the record-store import.
        let ignoredContentPaths: Set<String> = ["manifest.json", ProvenanceRecorder.provenanceFilename]

        for relativePath in lhsFiles {
            guard !ignoredContentPaths.contains(relativePath),
                  !relativePath.hasPrefix("provenance/"),
                  !relativePath.hasSuffix(ProvenanceRecorder.provenanceFilename) else { continue }
            let lhsData = try Data(contentsOf: lhs.appendingPathComponent(relativePath))
            let rhsData = try Data(contentsOf: rhs.appendingPathComponent(relativePath))
            XCTAssertEqual(
                lhsData, rhsData,
                "Content mismatch for \(relativePath) between off-main and on-main builds"
            )
        }

        // Manifests differ only in name/identifier (which came from distinct
        // configuration names in the two runs); genome/annotation/variant
        // shape must match exactly.
        let lhsManifest = try BundleManifest.load(from: lhs)
        let rhsManifest = try BundleManifest.load(from: rhs)
        XCTAssertEqual(lhsManifest.genome?.chromosomes.map(\.name), rhsManifest.genome?.chromosomes.map(\.name))
        XCTAssertEqual(lhsManifest.genome?.chromosomes.map(\.length), rhsManifest.genome?.chromosomes.map(\.length))
        XCTAssertEqual(lhsManifest.genome?.totalLength, rhsManifest.genome?.totalLength)
        XCTAssertEqual(lhsManifest.genome?.indexPath, rhsManifest.genome?.indexPath)
        XCTAssertEqual(lhsManifest.annotations.count, rhsManifest.annotations.count)
        XCTAssertEqual(lhsManifest.variants.count, rhsManifest.variants.count)
    }

    /// Confirms checkRequiredTools() also runs cleanly from a background
    /// actor with no MainActor hop required.
    func testCheckRequiredToolsRunsOffMain() async throws {
        let root = try makeFixtureRoot()
        let home = root.appendingPathComponent("home", isDirectory: true)

        let missing = await BackgroundToolChecker().checkTools(homeDirectory: home)
        XCTAssertNotNil(missing, "With no managed tools installed, samtools/bgzip should be reported missing")
    }
}

private actor BackgroundToolChecker {
    func checkTools(homeDirectory: URL) async -> NativeBundleBuilder.MissingToolsInfo? {
        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
        )
        return await builder.checkRequiredTools()
    }
}

/// Runs a build entirely on the main actor, mirroring how the rest of the
/// NativeBundleBuilder test suite (which is @MainActor) drives it. A
/// free-standing @MainActor entry point (rather than a method on the
/// non-isolated test class) avoids sending task-isolated `self` across the
/// actor boundary.
@MainActor
private enum MainActorBuildRunner {
    static func build(
        configuration: BuildConfiguration,
        toolsHome: URL
    ) async throws -> URL {
        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: toolsHome)
        )
        return try await builder.build(configuration: configuration)
    }
}
