// ExplicitLockReconcileTests.swift - Explicit conda locks govern tools update as well as pack installs
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// A fresh solve of `esviritu=1.3.3` on 2026-10-08 pulled in polars 2.0.0, which removed
/// `Expr.flatten`, and every EsViritu run then failed in `assembly_table_maker`. The pin alone
/// cannot prevent that, so EsViritu installs from an explicit lock, `tools update` uses the
/// lock too, and the planner reinstalls an environment whose packages drifted from it.
final class ExplicitLockReconcileTests: XCTestCase {
    private let esvirituSpec = "bioconda::esviritu=1.3.3=pyhdfd78af_0"

    private func manifest() -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [], managedData: [], dependencySet: "2026.2",
            packTools: [PackToolSpec(packID: "metagenomics", toolID: "esviritu", environment: "esviritu",
                                     packageSpec: esvirituSpec, executables: ["EsViritu"], version: "1.3.3",
                                     license: nil, sourceUrl: nil)],
            pipelines: [], databases: [],
            bootstrap: BootstrapSpec(micromamba: MicromambaSpec(version: "2.9.0-0", sha256: nil)),
            retiredEnvironments: [])
    }

    private func meta(_ name: String, _ version: String, _ build: String) -> CondaMetaPackage {
        .init(name: name, version: version, build: build, subdir: "noarch", channel: nil)
    }

    private func plan(onDisk: [CondaMetaPackage], locked: [LockedCondaPackage]?) -> ReconciliationPlan {
        var receipt = DependencyReceipt.empty()
        receipt.environments["esviritu"] = .init(packageSpec: esvirituSpec, packID: "metagenomics",
                                                 installedAt: Date(), state: .installed)
        return DependencyPlanner.plan(DependencyPlannerInputs(
            manifest: manifest(), receipt: receipt, installedEnvironments: ["esviritu": onDisk],
            installedPackIDs: ["metagenomics"], registryDatabaseVersions: [:], metagenomicsDatabaseVersions: [:],
            installedMicromambaVersion: "2.9.0-0",
            explicitLockPackages: locked.map { ["esviritu": $0] } ?? [:]))
    }

    private let locked = [
        LockedCondaPackage(name: "esviritu", version: "1.3.3", build: "pyhdfd78af_0"),
        LockedCondaPackage(name: "polars", version: "1.44.2", build: "pyh3138b34_0"),
    ]

    // MARK: - Planner

    func testEnvironmentWhoseDependenciesDriftedFromItsLockIsReinstalled() {
        let broken = plan(onDisk: [meta("esviritu", "1.3.3", "pyhdfd78af_0"), meta("polars", "2.0.0", "pyh3138b34_1")],
                          locked: locked)
        XCTAssertEqual(broken.reinstallEnvironments.map(\.environment), ["esviritu"])
        XCTAssertEqual(broken.reinstallEnvironments.first?.reason, .lockMismatch)
    }

    func testEnvironmentWithAnExtraPackageIsReinstalled() {
        let extra = plan(onDisk: [meta("esviritu", "1.3.3", "pyhdfd78af_0"), meta("polars", "1.44.2", "pyh3138b34_0"),
                                  meta("pandas", "3.0.0", "py314_0")],
                         locked: locked)
        XCTAssertEqual(extra.reinstallEnvironments.first?.reason, .lockMismatch)
    }

    func testEnvironmentMatchingItsLockIsCurrent() {
        let current = plan(onDisk: [meta("polars", "1.44.2", "pyh3138b34_0"), meta("esviritu", "1.3.3", "pyhdfd78af_0")],
                           locked: locked)
        XCTAssertTrue(current.isEmpty, "\(current)")
    }

    func testWithoutALockOnlyThePinIsChecked() {
        let unlocked = plan(onDisk: [meta("esviritu", "1.3.3", "pyhdfd78af_0"), meta("polars", "2.0.0", "pyh3138b34_1")],
                            locked: nil)
        XCTAssertTrue(unlocked.isEmpty, "\(unlocked)")
    }

    // MARK: - Reading a lock

    func testLockedPackagesParseNamesThatContainHyphens() {
        let text = """
        # platform: osx-arm64
        @EXPLICIT
        https://conda.anaconda.org/conda-forge/osx-arm64/clang_osx-arm64-23.1.1-h1ab324d_34.conda#\(String(repeating: "a", count: 32))
        https://conda.anaconda.org/conda-forge/noarch/polars-1.44.2-pyh3138b34_0.conda#\(String(repeating: "b", count: 32))
        https://conda.anaconda.org/conda-forge/osx-arm64/libzlib-1.3.1-h8359307_2.tar.bz2#\(String(repeating: "c", count: 32))
        """
        XCTAssertEqual(ManagedCondaExplicitLockSpec.lockedPackages(fromExplicitText: text), [
            LockedCondaPackage(name: "clang_osx-arm64", version: "23.1.1", build: "h1ab324d_34"),
            LockedCondaPackage(name: "polars", version: "1.44.2", build: "pyh3138b34_0"),
            LockedCondaPackage(name: "libzlib", version: "1.3.1", build: "h8359307_2"),
        ])
    }

    func testEveryBundledLockParsesEveryPackageLine() throws {
        let bundled = ManagedToolLock.bundled
        XCTAssertFalse(bundled.explicitLocks.isEmpty)
        for lock in bundled.explicitLocks {
            let text = try String(contentsOf: lock.validatedResourceURL(), encoding: .utf8)
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("https://") }
            XCTAssertEqual(try lock.lockedPackages().count, lines.count, lock.resource)
        }
        XCTAssertEqual(Set(bundled.explicitLockPackages().keys), ["esviritu", "olivar", "varvamp"])
    }

    // MARK: - The bundled EsViritu lock

    func testBundledEsVirituLockHoldsThePinAndKeepsPolarsBelowTwo() throws {
        let bundled = ManagedToolLock.bundled
        let lock = try XCTUnwrap(bundled.explicitLock(forEnvironment: "esviritu"))
        XCTAssertEqual(lock.packID, "metagenomics")
        let packages = try lock.lockedPackages()
        let pin = try XCTUnwrap(CondaSpec(spec: try XCTUnwrap(bundled.packageSpec(forEnvironment: "esviritu"))))
        XCTAssertTrue(packages.contains(LockedCondaPackage(name: pin.name, version: pin.version, build: pin.build ?? "")),
                      "the lock must install the manifest's EsViritu pin")
        let polars = try XCTUnwrap(packages.first { $0.name == "polars" })
        XCTAssertEqual(polars.version.split(separator: ".").first, "1",
                       "EsViritu 1.3.3 calls Expr.flatten, which polars 2 removed")
        let requirement = try XCTUnwrap(PluginPack.builtIn.lazy.flatMap(\.toolRequirements).first { $0.environment == "esviritu" })
        XCTAssertEqual(requirement.explicitLock, lock, "conda install --pack must use the same lock")
    }

    // MARK: - Installing

    func testToolsUpdateInstallsALockedEnvironmentFromItsLock() throws {
        let packages = try ReconcilerServices.installPackages(environment: "esviritu", spec: esvirituSpec,
                                                              manifest: .bundled)
        XCTAssertEqual(packages.first, "--file")
        XCTAssertEqual(packages.last.map { URL(fileURLWithPath: $0).lastPathComponent }, "esviritu-osx-arm64-explicit.txt")
        XCTAssertEqual(try ReconcilerServices.installPackages(environment: "samtools", spec: "bioconda::samtools=1.24",
                                                              manifest: .bundled),
                       ["bioconda::samtools=1.24"])
    }
}
