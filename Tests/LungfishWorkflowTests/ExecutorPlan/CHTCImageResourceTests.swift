// CHTCImageResourceTests.swift - The CHTC tool image's committed identity and manifest copy (CHTC lane I, M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// `Resources/CHTCImage/image-manifest.json` is a byte copy of `/opt/lungfish/image-manifest.json` in the CHTC tool
/// image, and `image.json` beside it states the image's SIF (file name, SHA-256, size) and the manifest's SHA-256 and
/// size. The plan writer takes the plan's `imageManifest` pin from `image.json` and the tool pins from the copy, and the
/// executor refuses a plan whose pin differs from the manifest it reads, so the two files have to agree. The tests read
/// the files the LungfishWorkflow resource bundle holds, as the app and the plan writer do.
final class CHTCImageResourceTests: XCTestCase {
    private struct FilePin: Decodable {
        let sha256: String
        let size: Int
    }

    private struct SIFPin: Decodable {
        let fileName: String
        let sha256: String
        let size: Int
    }

    /// The members of `image.json` that the launcher and the plan writer read. Its `build` object is not read by them.
    private struct ImageIdentity: Decodable {
        let schemaVersion: Int
        let sif: SIFPin
        let imageManifest: FilePin
    }

    /// The `build` object of `image.json`: the facts of the one build whose SIF is pinned (ARCH-M-IMAGE item 7).
    private struct BuildRecord: Decodable {
        let base: String
        let builtAt: String
        let chtcCluster: Int
        let chtcHost: String
        let executorSHA256: String
        let manifestToolCount: Int
        let toolsLockSHA256: String
        let trimGaloreLockSHA256: String
        let rnaseqLockSHA256: String
        let star273aLockSHA256: String
    }

    private struct BuildIdentity: Decodable {
        let build: BuildRecord
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isLowercaseDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func bundledBytes(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            RuntimeResourceLocator.path("CHTCImage/\(name)", in: .workflow),
            "CHTCImage/\(name) is not in the LungfishWorkflow resource bundle"
        )
        return try Data(contentsOf: url)
    }

    private func bundledIdentity() throws -> ImageIdentity {
        try JSONDecoder().decode(ImageIdentity.self, from: bundledBytes("image.json"))
    }

    func testCHTCImageManifestCopyMatchesItsPin() throws {
        let pin = try bundledIdentity().imageManifest
        let copy = try bundledBytes("image-manifest.json")
        XCTAssertEqual(sha256(copy), pin.sha256, "image-manifest.json differs from the SHA-256 that image.json pins")
        XCTAssertEqual(copy.count, pin.size, "image-manifest.json differs from the size that image.json pins")
    }

    func testCHTCImageIdentityNamesTheSIFByItsDigest() throws {
        let identity = try bundledIdentity()
        XCTAssertEqual(identity.schemaVersion, 1)
        XCTAssertTrue(isLowercaseDigest(identity.sif.sha256), "sif.sha256 is not 64 lowercase hex digits")
        XCTAssertTrue(isLowercaseDigest(identity.imageManifest.sha256), "imageManifest.sha256 is not 64 lowercase hex digits")
        XCTAssertEqual(identity.sif.fileName, "lge-tools-\(identity.sif.sha256.prefix(12)).sif")
        XCTAssertGreaterThan(identity.sif.size, 0)
        XCTAssertGreaterThan(identity.imageManifest.size, 0)
    }

    func testCHTCImageManifestCopyDecodesAsTheExecutorsManifest() throws {
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        XCTAssertFalse(manifest.tools.isEmpty)
        // The tools of the VSP2 cleanup recipe, which the first CHTC plan pins from this manifest.
        for id in ["fastp", "deacon", "seqkit", "pigz", "clumpify.sh"] {
            XCTAssertTrue(manifest.tools.contains { $0.id == id }, "the image manifest lists no tool \(id)")
            XCTAssertNotNil(try? manifest.pin(forToolID: id), "\(id) has no single version and build in the image manifest")
        }
    }

    // MARK: - The RNA-seq build (EX-IMAGE part 2, ARCH-M-IMAGE items 7 and 9)

    /// The five tools of the 5.3 chain at the builds the locks pin: STAR 2.7.11b, salmon and subread are the linux-64
    /// builds of the LINUX-HOST run that BIO passed, and STAR 2.7.3a has a prefix of its own. The manifest lists `STAR`
    /// twice by design, so a plan names it by version and build and never by id.
    func testCHTCImageManifestListsTheRNASeqToolsAtTheirBuilds() throws {
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        let expected: [(id: String, version: String, build: String, path: String, package: String)] = [
            ("salmon", "2.11.0", "hfa8f182_0", "/opt/lge/rnaseq/bin/salmon", "salmon"),
            ("STAR", "2.7.11b", "h5814d7d_9", "/opt/lge/rnaseq/bin/STAR", "star"),
            ("STAR", "2.7.3a", "h5ca1c30_1", "/opt/lge/star273a/bin/STAR", "star"),
            ("featureCounts", "2.1.1", "h577a1d6_0", "/opt/lge/rnaseq/bin/featureCounts", "subread"),
            ("umi_tools", "1.1.6", "py311haab0aaa_0", "/opt/lge/rnaseq/bin/umi_tools", "umi_tools"),
        ]
        for row in expected {
            let pin = PlanToolPin(id: row.id, version: row.version, build: row.build)
            let listed = manifest.tools.filter { $0.pin == pin }
            XCTAssertEqual(listed.count, 1, "\(row.id) \(row.version) \(row.build) is listed once")
            XCTAssertEqual(listed.first?.path, row.path, "\(row.id) \(row.version) path")
            XCTAssertEqual(listed.first?.condaPackage, row.package, "\(row.id) \(row.version) conda package")
            XCTAssertEqual(manifest.tool(matching: pin)?.path, row.path, "\(row.id) \(row.version) is the tool its pin runs")
        }
        for id in ["salmon", "featureCounts", "umi_tools"] {
            XCTAssertNoThrow(try manifest.pin(forToolID: id), "\(id) has one version and build")
        }
        XCTAssertThrowsError(try manifest.pin(forToolID: "STAR")) { error in
            XCTAssertEqual((error as? ImageToolManifestError)?.field, "tools")
        }
        XCTAssertEqual(manifest.tools.filter { $0.id == "STAR" }.map(\.version).sorted(), ["2.7.11b", "2.7.3a"])
    }

    /// The 10x barcode list `3M-february-2018` is the image's one data file, at the SHA-256 and size that
    /// `build-image.sh` pins and checks. The list itself is in the SIF and never in this tree or the Mac app.
    func testCHTCImageManifestHoldsTheBarcodeListAtItsPin() throws {
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        let sha256 = "843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b"
        XCTAssertEqual(manifest.files, [
            ImageDataFile(path: "/opt/lge/barcodes/3M-february-2018.txt", role: "barcodeList", sha256: sha256, size: 115_512_960)
        ])
        XCTAssertEqual(manifest.file(role: .barcodeList, sha256: sha256)?.path, "/opt/lge/barcodes/3M-february-2018.txt")
    }

    /// `image.json`'s build record names the four locks the build installed and the manifest's tool count, so a lock that
    /// changes after the build fails here until the image is built again and pinned again (ARCH-M-IMAGE item 9).
    func testCHTCImageBuildRecordNamesTheCommittedLocksAndTheManifestsToolCount() throws {
        let build = try JSONDecoder().decode(BuildIdentity.self, from: bundledBytes("image.json")).build
        let linux = try ManagedToolLock.loadLinux64FromBundle()
        let recorded: [(environment: String, sha256: String)] = [
            ("lge-tools", build.toolsLockSHA256), ("trim_galore", build.trimGaloreLockSHA256),
            ("rnaseq", build.rnaseqLockSHA256), ("star273a", build.star273aLockSHA256),
        ]
        for (environment, sha256) in recorded {
            let lock = try XCTUnwrap(linux.explicitLock(forEnvironment: environment), environment)
            XCTAssertEqual(sha256, lock.sha256, "the image was built from a \(environment) lock other than the committed one")
            // Throws when the committed file's bytes differ from the SHA-256 the lock JSON pins.
            XCTAssertNoThrow(try lock.validatedResourceURL(), environment)
        }
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        XCTAssertEqual(build.manifestToolCount, manifest.tools.count)
        XCTAssertTrue(build.base.hasPrefix("mambaorg/micromamba@sha256:"), "the base image is named by digest")
        XCTAssertTrue(isLowercaseDigest(build.executorSHA256), "executorSHA256 is not 64 lowercase hex digits")
        XCTAssertTrue(build.builtAt.hasSuffix("Z"), "builtAt is a UTC time, such as 2026-11-15T22:13:37Z")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: build.builtAt), "builtAt is an ISO 8601 time")
        XCTAssertGreaterThan(build.chtcCluster, 0)
        XCTAssertFalse(build.chtcHost.isEmpty)
    }

    /// Each tool of the manifest comes from a package of the lock of the prefix its path is in, and each of the four
    /// prefixes lists a tool. A manifest built from other locks than the committed ones shows here.
    func testEveryToolOfTheCHTCImageManifestComesFromAPackageOfTheLockOfItsPrefix() throws {
        let packages = try ManagedToolLock.loadLinux64FromBundle().explicitLockPackages().mapValues { Set($0) }
        let prefixes: [(folder: String, environment: String)] = [
            ("/opt/lge/env/", "lge-tools"), ("/opt/lge/trim_galore/", "trim_galore"),
            ("/opt/lge/rnaseq/", "rnaseq"), ("/opt/lge/star273a/", "star273a"),
        ]
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        var counts: [String: Int] = [:]
        for tool in manifest.tools {
            guard let prefix = prefixes.first(where: { tool.path.hasPrefix($0.folder) }) else {
                XCTFail("\(tool.path) is in no prefix of the image")
                continue
            }
            let package = LockedCondaPackage(name: tool.condaPackage, version: tool.version, build: tool.build)
            XCTAssertTrue(packages[prefix.environment]?.contains(package) == true,
                          "\(tool.path) comes from \(package.name) \(package.version) \(package.build), which the \(prefix.environment) lock does not install")
            counts[prefix.environment, default: 0] += 1
        }
        XCTAssertEqual(Set(counts.keys), Set(prefixes.map(\.environment)), "each of the four prefixes lists a tool")
    }

    /// The ids a recipe plan pins by name (`ExecutorPlanEmitter.ToolPins`): the BBTools wrappers and the `java` they
    /// find through PATH, fastp, deacon, seqkit, the compressors and Trim Galore. Each stays at one version and build
    /// now that the RNA-seq prefixes are in the image, since the plan writer drops an id listed twice and the plan
    /// then says the manifest lists no such tool.
    func testEveryToolIDARecipePlanPinsByNameHasOneVersionAndBuildInTheCHTCImageManifest() throws {
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        for id in ["clumpify.sh", "reformat.sh", "bbduk.sh", "bbmerge.sh", "repair.sh", "tadpole.sh", "java",
                   "fastp", "deacon", "seqkit", "pigz", "bgzip", "trim_galore"] {
            XCTAssertNoThrow(try manifest.pin(forToolID: id), "\(id) has no single version and build in the image manifest")
        }
    }
}
