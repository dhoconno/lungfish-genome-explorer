// DependencyReceiptStoreTests.swift - Tests for the dependency install receipt store
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class DependencyReceiptStoreTests: XCTestCase {
    private func tmpRoot() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func fakeEnv(root: URL, name: String, pkg: String, version: String, build: String) throws {
        let meta = root.appendingPathComponent("conda/envs/\(name)/conda-meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"name":"\#(pkg)","version":"\#(version)","build":"\#(build)","subdir":"osx-arm64","channel":"https://conda.anaconda.org/bioconda/osx-arm64"}"#
            .write(to: meta.appendingPathComponent("\(pkg)-\(version)-\(build).json"), atomically: true, encoding: .utf8)
    }

    func testRoundTrip() throws {
        let root = try tmpRoot()
        let store = DependencyReceiptStore(storageRoot: root)
        XCTAssertNil(try store.load())
        var r = DependencyReceipt.empty()
        r.dependencySet = "2026.1"
        r.environments["samtools"] = .init(
            packageSpec: "bioconda::samtools=1.23.1=hc612e98_0",
            packID: "lungfish-tools",
            installedAt: Date(),
            state: .installed
        )
        // save() stamps updatedAt and truncates dates to the ISO8601 on-disk resolution,
        // so the receipt as written is the value load() must reproduce.
        let written = try store.save(r)
        XCTAssertEqual(try store.load(), written)
        XCTAssertEqual(written.dependencySet, "2026.1")
        XCTAssertEqual(written.environments["samtools"]?.packageSpec, "bioconda::samtools=1.23.1=hc612e98_0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dependency-receipt.json").path))
    }

    func testSavedDatesSurviveRoundTripAtSecondResolution() throws {
        let root = try tmpRoot()
        let store = DependencyReceiptStore(storageRoot: root)
        var r = DependencyReceipt.empty()
        // A deliberately sub-second instant: ISO8601 keeps only whole seconds.
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.678)
        r.environments["samtools"] = .init(
            packageSpec: "bioconda::samtools=1.23.1=hc612e98_0",
            packID: "lungfish-tools",
            installedAt: fractional,
            state: .installed
        )
        r.databases["kraken2-standard-16"] = .init(version: "2026.1", path: "/db", installedAt: fractional)
        r.pipelines["nao-mgs"] = .init(revision: "v1.2.3", prefetchedAt: fractional)
        let written = try store.save(r)
        XCTAssertEqual(written.environments["samtools"]?.installedAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(written.databases["kraken2-standard-16"]?.installedAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(written.pipelines["nao-mgs"]?.prefetchedAt?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(try store.load(), written)
    }

    func testCorruptReceiptThrows() throws {
        let root = try tmpRoot()
        let store = DependencyReceiptStore(storageRoot: root)
        try "not json".write(to: store.receiptURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }

    func testSynthesizeFromCondaMeta() throws {
        let root = try tmpRoot()
        let store = DependencyReceiptStore(storageRoot: root)
        try fakeEnv(root: root, name: "samtools", pkg: "samtools", version: "1.23.1", build: "hc612e98_0")
        try fakeEnv(root: root, name: "bbtools", pkg: "bbmap", version: "39.80", build: "h2e3bd82_0")
        try fakeEnv(root: root, name: "trim_galore", pkg: "trim-galore", version: "2.3.0", build: "h48b4a6d_0")
        let manifest = try ManagedToolLock.loadFromBundle()
        let r = store.synthesize(condaRoot: root.appendingPathComponent("conda"), manifest: manifest)
        XCTAssertTrue(r.synthesized)
        XCTAssertNil(r.dependencySet)
        XCTAssertEqual(r.environments["samtools"]?.packageSpec, "bioconda::samtools=1.23.1=hc612e98_0")
        XCTAssertEqual(r.environments["bbtools"]?.packageSpec, "bioconda::bbmap=39.80=h2e3bd82_0")   // primary package name from manifest spec
        XCTAssertEqual(r.environments["trim_galore"]?.packageSpec, "bioconda::trim-galore=2.3.0=h48b4a6d_0")
        XCTAssertEqual(r.environments["samtools"]?.packID, manifest.packID)
    }

    func testSynthesizeFromInMemoryEnvironments() throws {
        let root = try tmpRoot()
        let store = DependencyReceiptStore(storageRoot: root)
        let manifest = try ManagedToolLock.loadFromBundle()
        let bioconda = "https://conda.anaconda.org/bioconda/osx-arm64"
        let environments: [String: [CondaMetaPackage]] = [
            "samtools": [
                CondaMetaPackage(name: "samtools", version: "1.23.1", build: "hc612e98_0", subdir: "osx-arm64", channel: bioconda),
                CondaMetaPackage(name: "libdeflate", version: "1.24", build: "h5773f1b_0", subdir: "osx-arm64", channel: bioconda)
            ],
            "bbtools": [
                CondaMetaPackage(name: "bbmap", version: "39.80", build: "h2e3bd82_0", subdir: "osx-arm64", channel: bioconda)
            ],
            "trim_galore": [
                CondaMetaPackage(name: "trim-galore", version: "2.3.0", build: "h48b4a6d_0", subdir: "osx-arm64", channel: bioconda)
            ],
            "empty-env": []
        ]
        let r = store.synthesize(environments: environments, manifest: manifest)
        XCTAssertTrue(r.synthesized)
        XCTAssertNil(r.dependencySet)
        XCTAssertEqual(r.environments["samtools"]?.packageSpec, "bioconda::samtools=1.23.1=hc612e98_0")
        XCTAssertEqual(r.environments["bbtools"]?.packageSpec, "bioconda::bbmap=39.80=h2e3bd82_0")
        XCTAssertEqual(r.environments["trim_galore"]?.packageSpec, "bioconda::trim-galore=2.3.0=h48b4a6d_0")
        XCTAssertNil(r.environments["empty-env"])
        XCTAssertEqual(r.environments["samtools"]?.state, .installed)
        XCTAssertEqual(r.environments["bbtools"]?.packID, manifest.packID)
    }
}
