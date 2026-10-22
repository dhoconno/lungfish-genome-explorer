// LinuxToolLockTests.swift - The linux-64 sibling of the managed tool lock mirrors the Mac lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishWorkflow

/// The CHTC image is built from `third-party-tools-lock.linux-64.json` and the two explicit files it
/// names. The linux-64 lock carries the Mac lock's tool versions with the build strings of the
/// linux-64 packages. The Mac lock stays as it is, since every Mac record states its SHA-256.
final class LinuxToolLockTests: XCTestCase {
    /// The Mac lock's SHA-256 when the linux-64 lock was added. A deliberate change to the Mac lock
    /// changes this literal in the same commit, and the linux-64 lock follows for the tools it carries.
    private static let macLockSHA256 = "586edb75c2f2402e2eb845526051cc39c7542291036d638927ab6289cfc37e26"

    /// The SHA-256 of C0's explicit file, the 87-package environment that slice 0's argv replay and
    /// deacon check ran on. A change to the image's tool set is a lane of its own that reruns both (K5.1).
    private static let sliceZeroEnvironmentSHA256 = "9bb6e82dd3516d28a8ebac4dafee930842b798c77e13b11a3104bbbb2cdec414"

    /// The Mac lock's tools the CHTC image does not carry. A tool added to the Mac lock fails the
    /// mirror test until it is named here or added to the linux-64 lock.
    private static let toolsTheImageDoesNotCarry: Set<String> = [
        // Workflow engines, Python tools and tools of other analyses, run on the Mac.
        "nextflow", "snakemake", "cutadapt", "vsearch", "sra-tools", "ucsc-bedgraphtobigwig", "pysam", "openpyxl",
        // samtools and zstd are in the image only as dependencies. bcftools and xz are not in it.
        "samtools", "bcftools", "zstd", "xz",
    ]

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The mirror

    func testLinuxLockMirrorsMacLockVersions() throws {
        let mac = try ManagedToolLock.loadFromBundle()
        let linux = try ManagedToolLock.loadLinux64FromBundle()
        let installed = linux.explicitLockPackages()

        let macIDs = Set(mac.tools.map(\.id))
        let linuxIDs = Set(linux.tools.map(\.id))
        XCTAssertEqual(linux.tools.count, linuxIDs.count, "a tool id appears once in the linux-64 lock")
        XCTAssertTrue(linuxIDs.isDisjoint(with: Self.toolsTheImageDoesNotCarry))
        XCTAssertEqual(macIDs, linuxIDs.union(Self.toolsTheImageDoesNotCarry),
                       "every Mac tool is in the linux-64 lock or named as left out of the image")
        XCTAssertEqual(linuxIDs, ["bbtools", "fastp", "deacon", "htslib", "seqkit", "pigz", "trim_galore"])

        for tool in linux.tools {
            let macTool = try XCTUnwrap(mac.tool(named: tool.id), tool.id)
            XCTAssertEqual(tool.version, macTool.version, "\(tool.id) version")
            XCTAssertEqual(tool.executables, macTool.executables, "\(tool.id) executables")
            let pinned = try XCTUnwrap(CondaSpec(spec: tool.packageSpec), tool.id)
            let macPinned = try XCTUnwrap(CondaSpec(spec: macTool.packageSpec), tool.id)
            XCTAssertEqual(pinned.name, macPinned.name, "\(tool.id) conda package")
            XCTAssertEqual(pinned.version, macPinned.version, "\(tool.id) pinned version")
            XCTAssertEqual(pinned.version, tool.version, "\(tool.id) pin and version agree")

            // The build string is the linux-64 package's: the environment's explicit lock installs it.
            let build = try XCTUnwrap(pinned.build, "\(tool.id) pins a build")
            let packages = try XCTUnwrap(installed[tool.environment], tool.environment)
            XCTAssertTrue(packages.contains(LockedCondaPackage(name: pinned.name, version: pinned.version, build: build)),
                          "\(pinned.name) \(pinned.version) \(build) is a package of the \(tool.environment) lock")
            let lock = try XCTUnwrap(linux.explicitLock(forEnvironment: tool.environment), tool.environment)
            let text = try String(contentsOf: lock.validatedResourceURL(), encoding: .utf8)
            XCTAssertTrue(text.contains("/linux-64/\(pinned.name)-\(pinned.version)-\(build)."),
                          "\(tool.id) comes from the linux-64 subdirectory")
        }
    }

    func testMacLockBytesUnchanged() throws {
        let identity = try XCTUnwrap(ManagedToolLock.bundledIdentity)
        XCTAssertEqual(identity.fileSHA256, Self.macLockSHA256,
                       "every Mac record states this SHA-256, so a deliberate Mac lock change updates the literal here")
        let onDisk = try Data(contentsOf: ManagedToolLock.resourceURL())
        XCTAssertEqual(sha256Hex(onDisk), Self.macLockSHA256)

        let mac = ManagedToolLock.bundled
        XCTAssertTrue(mac.explicitLocks.allSatisfy { $0.platform == "osx-arm64" })
        XCTAssertNil(mac.explicitLock(forEnvironment: "lge-tools"), "the linux-64 lock never merges into the Mac lock")
        XCTAssertNil(mac.explicitLock(forEnvironment: "trim_galore"))
        XCTAssertFalse(mac.explicitLockPackages().keys.contains("lge-tools"))
    }

    // MARK: - The explicit files

    func testLinuxExplicitFilesListEveryPackageByURLAndMD5() throws {
        let linux = try ManagedToolLock.loadLinux64FromBundle()
        XCTAssertEqual(Set(linux.explicitLocks.map(\.toolID)), Set(linux.tools.map(\.environment)),
                       "every environment of the linux-64 lock has one explicit file")
        for lock in linux.explicitLocks {
            XCTAssertEqual(lock.platform, "linux-64", lock.resource)
            // Throws when the file's SHA-256 differs from the lock's or a package URL is unsafe or unhashed.
            let text = try String(contentsOf: lock.validatedResourceURL(), encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init)

            var declared: Int?
            var previousComment: String?
            var packageLines = 0
            for line in lines {
                if line.hasPrefix("#") {
                    if line.contains(" packages. Comment lines give name, version, build string, channel and sha256") {
                        declared = Int(line.dropFirst(2).prefix { $0.isNumber })
                    }
                    previousComment = line
                    continue
                }
                guard line != "@EXPLICIT" else { continue }
                packageLines += 1
                let parts = line.split(separator: "#", omittingEmptySubsequences: false)
                XCTAssertEqual(parts.count, 2, "\(line) carries one #md5 fragment")
                let md5 = parts.last.map(String.init) ?? ""
                XCTAssertEqual(md5.count, 32, "\(line) md5")
                XCTAssertTrue(md5.allSatisfy { $0.isASCII && $0.isHexDigit }, "\(line) md5")
                XCTAssertTrue(line.hasPrefix("https://conda.anaconda.org/"), line)
                XCTAssertTrue(line.contains("/linux-64/") || line.contains("/noarch/"), "\(line) is not a macOS package")

                // The comment line before each URL names the same package and gives its sha256.
                let package = try XCTUnwrap(LockedCondaPackage(packageURL: line), line)
                let fields = (previousComment ?? "").dropFirst(2).split(separator: " ").map(String.init)
                XCTAssertEqual(fields.count, 5, "\(line) follows a comment of name, version, build, channel and sha256")
                XCTAssertEqual(Array(fields.prefix(3)), [package.name, package.version, package.build], line)
                XCTAssertTrue(fields.last?.hasPrefix("sha256:") == true && fields.last?.count == 71, "\(line) sha256")
            }
            XCTAssertGreaterThan(packageLines, 0, lock.resource)
            XCTAssertEqual(declared, packageLines, "\(lock.resource) states its package count")
            XCTAssertEqual(try lock.lockedPackages().count, packageLines, lock.resource)
        }
    }

    func testImageEnvironmentsAreSliceZerosLockAndTrimGaloresOwn() throws {
        let linux = try ManagedToolLock.loadLinux64FromBundle()
        let toolsLock = try XCTUnwrap(linux.explicitLock(forEnvironment: "lge-tools"))
        XCTAssertEqual(toolsLock.sha256, Self.sliceZeroEnvironmentSHA256,
                       "a change to the image's tool set is a lane of its own that reruns slice 0 (K5.1)")
        let installed = linux.explicitLockPackages()
        let tools = try XCTUnwrap(installed["lge-tools"])
        XCTAssertEqual(tools.count, 87)
        XCTAssertFalse(tools.contains { $0.name == "trim-galore" }, "Trim Galore does not change slice 0's environment")

        let trim = try XCTUnwrap(installed["trim_galore"])
        XCTAssertTrue(trim.contains { $0.name == "trim-galore" && $0.version == "2.3.0" })
        XCTAssertEqual(linux.tool(named: "trim_galore")?.environment, "trim_galore")
        for tool in linux.tools where tool.id != "trim_galore" {
            XCTAssertEqual(tool.environment, "lge-tools", tool.id)
        }
    }

    // MARK: - Reading the platform

    func testExplicitLockNamesItsPlatformInItsResource() throws {
        func spec(_ platform: String, _ resource: String) -> ManagedCondaExplicitLockSpec {
            ManagedCondaExplicitLockSpec(packID: "pack", toolID: "tool", platform: platform, resource: resource,
                                         sha256: String(repeating: "a", count: 64))
        }
        XCTAssertNoThrow(try spec("linux-64", "tool-linux-64-explicit.txt").validateIdentity())
        XCTAssertNoThrow(try spec("osx-arm64", "tool-osx-arm64-explicit.txt").validateIdentity())
        XCTAssertThrowsError(try spec("linux-64", "tool-osx-arm64-explicit.txt").validateIdentity())
        XCTAssertThrowsError(try spec("osx-arm64", "tool-linux-64-explicit.txt").validateIdentity())
        XCTAssertThrowsError(try spec("win-64", "tool-win-64-explicit.txt").validateIdentity())
        XCTAssertThrowsError(try spec("linux-64", "../tool-linux-64-explicit.txt").validateIdentity())
    }

    func testLinux64LockIdentityIsTheSHA256OfItsBytes() throws {
        let identity = try XCTUnwrap(ManagedToolLock.bundledLinux64Identity)
        let data = try Data(contentsOf: ManagedToolLock.resourceURL(named: ManagedToolLock.linux64ResourceName))
        XCTAssertEqual(identity.fileSHA256, sha256Hex(data))
        XCTAssertNotEqual(identity.fileSHA256, ManagedToolLock.bundledIdentity?.fileSHA256)
        XCTAssertEqual(identity.lockVersion, try ManagedToolLock.loadLinux64FromBundle().version)
    }
}
