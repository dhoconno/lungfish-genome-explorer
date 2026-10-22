// RibokmersPinnedDownloadTests.swift - The ribokmers index installs as one hosted download the lock pins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import LungfishIO
import LungfishTestSupport
import Synchronization
import XCTest
@testable import LungfishWorkflow

/// `deacon-ribokmers` is built once with the pinned deacon, hosted on the LGE large-files folder, and pinned by
/// SHA-256 and size in the lock (CHTC lane C2-RIBOPIN, owner answer Q10). Every test serves the index from a local
/// file URL through the registry's download seam, so none touches the network.
final class RibokmersPinnedDownloadTests: XCTestCase {
    private static let databaseID = "deacon-ribokmers"
    private static let hostedURL = "https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/databases/"
        + "deacon-ribokmers/k31w15-deacon0.16.0-1thread-2026-10-22/ribokmers.k31w15.idx"

    private var tempDir: URL!
    private var preferencesSuite: TestDefaultsSuite!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ribokmers-pin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        preferencesSuite = makeTestDefaultsSuite(prefix: "RibokmersPinnedDownloadTests")
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// A fresh install downloads the file the lock names, checks it, publishes it and writes an install record that
    /// names the download, the file's real digest and the build the lock records, with the build's reproducibility,
    /// minimizer count, set digest, set method and note. No tool runs.
    func testFreshInstallDownloadsThePinnedFileAndRecordsTheBuild() async throws {
        let words: [UInt64] = [5, 90, 17, 1_000_000, 42]
        let payload = Self.deaconIndex(words: words)
        let served = try serve(payload, as: "served.idx")
        let requests = RibokmersSeamLog<URL>()
        let tools = RibokmersSeamLog<String>()
        let registry = makeRegistry(
            spec: try spec(pinning: payload, url: served, minimizerSet: (words.count, Self.setDigest(of: words))),
            requests: requests,
            tools: tools
        )

        let installed = try await registry.installManagedDatabase(Self.databaseID, reinstall: true)

        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertEqual(installed.lastPathComponent, "ribokmers.k31w15.idx")
        XCTAssertEqual(requests.values, [served], "The install must download the URL the lock names")
        XCTAssertEqual(tools.values, [], "A pinned download builds nothing")
        let resolved = await registry.effectiveDatabasePath(for: Self.databaseID)
        XCTAssertEqual(resolved?.standardizedFileURL, installed.standardizedFileURL)

        let run = try installRecord(beside: installed)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["databaseID"]?.stringValue, Self.databaseID)
        XCTAssertEqual(run.parameters["installSource"]?.stringValue, "pinned-download")
        XCTAssertEqual(run.parameters["downloadUrl"]?.stringValue, served.absoluteString)
        XCTAssertEqual(run.parameters["pinnedSHA256"]?.stringValue, Self.sha256(payload))
        XCTAssertEqual(run.parameters["buildToolVersion"]?.stringValue, "0.16.0")
        XCTAssertEqual(run.parameters["buildSourceUrl"]?.stringValue, "https://bbmap.org/resources/ribokmers.fa.gz")
        XCTAssertEqual(run.parameters["buildSourceSHA256"]?.stringValue, String(repeating: "a", count: 64))
        XCTAssertEqual(run.parameters["buildArgv"], .array(Self.buildArgv.map { .string($0) }))
        XCTAssertEqual(run.parameters["buildByteReproducible"], .boolean(true))
        XCTAssertEqual(run.parameters["buildMinimizerCount"], .integer(5))
        XCTAssertEqual(run.parameters["buildMinimizerSetSHA256"]?.stringValue, Self.setDigest(of: words))
        XCTAssertEqual(run.parameters["buildMinimizerSetMethod"]?.stringValue, Self.fixtureMinimizerSetMethod)
        XCTAssertEqual(run.parameters["buildNote"]?.stringValue, Self.fixtureBuildNote)
        XCTAssertEqual(run.steps.map(\.toolName), ["URLSession"])
        let output = try XCTUnwrap(run.steps.first?.outputs.first)
        XCTAssertEqual(output.path, installed.path)
        XCTAssertEqual(output.sha256, Self.sha256(payload), "The record names the real digest of the published file")
        XCTAssertEqual(output.sizeBytes, UInt64(payload.count))
        XCTAssertEqual(run.steps.first?.inputs.first?.path, served.absoluteString)
    }

    /// A downloaded file that is not the pinned one, by size or by digest, is refused with the install error, and
    /// the install publishes nothing: no index, partial file or record.
    func testInstallRefusesADownloadThatIsNotThePinnedFileAndPublishesNothing() async throws {
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let sameSize = Data("PINNED-RIBOKMERS-INDEX\n".utf8)
        let otherSize = Data("a shorter index\n".utf8)
        let cases: [(Data, String)] = [
            (sameSize, "The index's SHA-256 is \(Self.sha256(sameSize)), and the bundled lock pins \(Self.sha256(pinned))."),
            (otherSize, "The index is \(otherSize.count) bytes, and the bundled lock pins \(pinned.count) bytes."),
        ]
        for (index, (servedBytes, expectedReason)) in cases.enumerated() {
            let served = try serve(servedBytes, as: "served-\(index).idx")
            let userRoot = tempDir.appendingPathComponent("user-databases-\(index)", isDirectory: true)
            let registry = makeRegistry(spec: try spec(pinning: pinned, url: served), userRoot: userRoot)

            do {
                _ = try await registry.installManagedDatabase(Self.databaseID, reinstall: true)
                XCTFail("The install published a file the lock does not pin")
            } catch HumanScrubberDatabaseError.installationFailed(let databaseID, _, let reason) {
                XCTAssertEqual(databaseID, Self.databaseID)
                XCTAssertEqual(reason, expectedReason)
            }
            XCTAssertEqual(regularFileNames(under: userRoot), [], "A refused install must publish nothing")
            let resolved = await registry.effectiveDatabasePath(for: Self.databaseID)
            XCTAssertNil(resolved)
        }
    }

    /// An index that an earlier install built on its own host differs from the hosted build's pin. A recipe step
    /// that reads it is not refused, and its record names the file's real digest as not lock-pinned.
    func testRecipeRecordOfAnIndexThatDiffersFromTheHostedPinIsNotRefused() async throws {
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let spec = try spec(pinning: pinned, url: URL(string: Self.hostedURL)!)
        let hostBuiltURL = try serve(hostBuilt, as: "host-built.idx")
        let pinnedURL = try serve(pinned, as: "pinned.idx")
        let identity = RecipeDatabaseIdentity()

        let differing = try await identity.record(databaseID: Self.databaseID, spec: spec, at: hostBuiltURL)
        XCTAssertEqual(differing.sha256, Self.sha256(hostBuilt))
        XCTAssertEqual(differing.sizeBytes, Int64(hostBuilt.count))
        XCTAssertFalse(differing.lockPinned)

        let matching = try await identity.record(databaseID: Self.databaseID, spec: spec, at: pinnedURL)
        XCTAssertEqual(matching.sha256, Self.sha256(pinned))
        XCTAssertTrue(matching.lockPinned)
        // The pinned file's record keeps the build facts the lock holds, so an import record that runs the rRNA step
        // still names the source the index was built from. An index that differs has no install record to read them from.
        XCTAssertEqual(matching.buildSourceSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(matching.buildToolVersion, "0.16.0")
        XCTAssertEqual(matching.buildSourceSizeBytes, 12)
        XCTAssertNil(differing.buildSourceSHA256)
    }

    /// The bundled lock names the hosted file, its SHA-256 and size, as a pinned HTTPS download.
    func testBundledLockPinsTheHostedRibokmersBuild() throws {
        let spec = try XCTUnwrap(ManagedToolLock.bundled.database(id: Self.databaseID))
        XCTAssertEqual(spec.url, Self.hostedURL)
        XCTAssertEqual(spec.sha256, "f88286f607bc062ef872b55cac9aff1d447f7106068cafefef72a3ba8e49ede6")
        XCTAssertEqual(spec.sizeBytes, 10_107_947)
        XCTAssertEqual(spec.filename, "ribokmers.k31w15.idx")
        XCTAssertEqual(spec.effectiveSourcePolicy, .pinnedArchive)
        XCTAssertNoThrow(try spec.validateSourceIdentity())
    }

    /// An index an earlier install built on its own host is reported as differing from the pinned build and stays
    /// usable. An update replaces it with the pinned file, after which the status reports a match.
    func testStatusReportsAnIndexThatDiffersFromThePinAndUpdateReplacesIt() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let earlier = makeRegistry(spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")))
        let earlierInstall = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let registry = makeRegistry(spec: try spec(pinning: pinned, url: try serve(pinned, as: "pinned.idx")))

        let before = try await registry.pinStatus(for: Self.databaseID)
        XCTAssertEqual(before, .differsFromPin(installedSHA256: Self.sha256(hostBuilt), pinnedSHA256: Self.sha256(pinned)))
        XCTAssertTrue(before.summary(databaseID: Self.databaseID).contains("differs from the pinned build"))
        let resolved = await registry.effectiveDatabasePath(for: Self.databaseID)
        XCTAssertEqual(resolved?.standardizedFileURL, earlierInstall.standardizedFileURL, "A differing index stays usable")

        let updated = try await registry.updateManagedDatabase(Self.databaseID)

        XCTAssertEqual(try Data(contentsOf: updated), pinned)
        let after = try await registry.pinStatus(for: Self.databaseID)
        XCTAssertEqual(after, .matchesPin(sha256: Self.sha256(pinned)))
        XCTAssertEqual(try installRecord(beside: updated).steps.first?.outputs.first?.sha256, Self.sha256(pinned))
    }

    /// An update whose download is not the pinned file is refused, and the installed index and its record stay.
    func testRefusedUpdateLeavesTheInstalledIndexInPlace() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let earlier = makeRegistry(spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")))
        let installed = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let recordURL = installed.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let recordBefore = try Data(contentsOf: recordURL)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let wrong = try serve(Data("PINNED-RIBOKMERS-INDEX\n".utf8), as: "wrong.idx")
        let registry = makeRegistry(spec: try spec(pinning: pinned, url: wrong))

        do {
            _ = try await registry.updateManagedDatabase(Self.databaseID)
            XCTFail("The update published a file the lock does not pin")
        } catch HumanScrubberDatabaseError.installationFailed(let databaseID, _, _) {
            XCTAssertEqual(databaseID, Self.databaseID)
        }
        XCTAssertEqual(try Data(contentsOf: installed), hostBuilt)
        XCTAssertEqual(try Data(contentsOf: recordURL), recordBefore)
        XCTAssertEqual(
            regularFileNames(under: installed.deletingLastPathComponent()),
            [ProvenanceRecorder.provenanceFilename, "ribokmers.k31w15.idx"].sorted()
        )
    }

    /// An update whose install record cannot be written leaves the installed index and its record as they were, since
    /// the old index is the user's working copy and the new one is only a candidate.
    func testFailedRecordDuringUpdateKeepsTheInstalledIndexAndItsRecord() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let earlier = makeRegistry(spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")))
        let installed = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let recordURL = installed.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let recordBefore = try Data(contentsOf: recordURL)
        let registry = makeRegistry(
            spec: try spec(pinning: pinned, url: try serve(pinned, as: "pinned.idx")),
            provenanceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        do {
            _ = try await registry.updateManagedDatabase(Self.databaseID)
            XCTFail("The update succeeded without its record")
        } catch HumanScrubberDatabaseError.installationFailed(let databaseID, _, let reason) {
            XCTAssertEqual(databaseID, Self.databaseID)
            XCTAssertTrue(reason.contains("managed database install provenance"), reason)
        }
        XCTAssertEqual(try Data(contentsOf: installed), hostBuilt)
        XCTAssertEqual(try Data(contentsOf: recordURL), recordBefore)
        XCTAssertEqual(
            regularFileNames(under: installed.deletingLastPathComponent()),
            [ProvenanceRecorder.provenanceFilename, "ribokmers.k31w15.idx"].sorted()
        )
    }

    /// An index whose install record cannot be written does not stay published, and a cancelled download publishes
    /// nothing.
    func testFailedRecordAndCancelledDownloadPublishNothing() async throws {
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let served = try serve(pinned, as: "pinned.idx")
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let failingRecord = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            provenanceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        do {
            _ = try await failingRecord.installManagedDatabase(Self.databaseID, reinstall: true)
            XCTFail("The install succeeded without its record")
        } catch HumanScrubberDatabaseError.installationFailed(_, _, let reason) {
            XCTAssertTrue(reason.contains("managed database install provenance"), reason)
        }
        XCTAssertEqual(regularFileNames(under: userRoot), [])
        XCTAssertNil(preferencesSuite.defaults.string(forKey: "database.deacon-ribokmers.overrideFilename"))

        let cancelled = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            downloader: { _, _ in throw CancellationError() }
        )
        do {
            _ = try await cancelled.installManagedDatabase(Self.databaseID, reinstall: true)
            XCTFail("A cancelled download installed an index")
        } catch HumanScrubberDatabaseError.installationCancelled(let databaseID, _) {
            XCTAssertEqual(databaseID, Self.databaseID)
        }
        XCTAssertEqual(regularFileNames(under: userRoot), [])
    }

    /// Another channel's copy of the index is cloned only when it is the file this build's lock pins. A sibling copy
    /// that an older build installed from another pin is not the pinned file, so the install downloads the pinned one.
    func testASiblingCopyThatIsNotThePinnedFileIsNotCloned() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let siblingRoot = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let sibling = makeRegistry(
            spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")), userRoot: siblingRoot
        )
        _ = try await sibling.installManagedDatabase(Self.databaseID, reinstall: true)
        let served = try serve(pinned, as: "pinned.idx")
        let requests = RibokmersSeamLog<URL>()
        let registry = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            userRoot: tempDir.appendingPathComponent("preview-root/databases", isDirectory: true),
            requests: requests,
            siblingDatabaseRoots: [siblingRoot]
        )

        let installed = try await registry.installManagedDatabase(Self.databaseID)

        XCTAssertEqual(requests.values, [served], "A sibling copy that is not the pinned file must not stand in for the download")
        XCTAssertEqual(try Data(contentsOf: installed), pinned)
        XCTAssertEqual(try installRecord(beside: installed).parameters["installSource"]?.stringValue, "pinned-download")
    }

    /// A sibling copy that is the pinned file, verified against its own install record, is cloned without a download.
    func testASiblingCopyThatIsThePinnedFileIsCloned() async throws {
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let served = try serve(pinned, as: "pinned.idx")
        let siblingRoot = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let sibling = makeRegistry(spec: try spec(pinning: pinned, url: served), userRoot: siblingRoot)
        _ = try await sibling.installManagedDatabase(Self.databaseID, reinstall: true)
        let requests = RibokmersSeamLog<URL>()
        let registry = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            userRoot: tempDir.appendingPathComponent("preview-root/databases", isDirectory: true),
            requests: requests,
            siblingDatabaseRoots: [siblingRoot]
        )

        let installed = try await registry.installManagedDatabase(Self.databaseID)

        XCTAssertEqual(requests.values, [], "A verified sibling copy of the pinned file replaces the download")
        XCTAssertEqual(try Data(contentsOf: installed), pinned)
        XCTAssertEqual(try installRecord(beside: installed).parameters["installSource"]?.stringValue, "sibling-root-clone")
    }

    /// An update replaces an index the user already has, so it downloads the pinned file and publishes it through the
    /// durable swap even when another channel holds the pinned file. Only an install with nothing at the name clones.
    func testUpdateOfADifferingIndexDownloadsWhenASiblingHoldsThePinnedFile() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let served = try serve(pinned, as: "pinned.idx")
        let siblingRoot = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let previewRoot = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        let sibling = makeRegistry(spec: try spec(pinning: pinned, url: served), userRoot: siblingRoot)
        _ = try await sibling.installManagedDatabase(Self.databaseID, reinstall: true)
        let earlier = makeRegistry(
            spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")), userRoot: previewRoot
        )
        _ = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let requests = RibokmersSeamLog<URL>()
        let registry = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            userRoot: previewRoot,
            requests: requests,
            siblingDatabaseRoots: [siblingRoot]
        )

        let updated = try await registry.updateManagedDatabase(Self.databaseID)

        XCTAssertEqual(requests.values, [served], "An update replaces an installed index, so it downloads and never clones")
        XCTAssertEqual(try Data(contentsOf: updated), pinned)
        XCTAssertEqual(try installRecord(beside: updated).parameters["installSource"]?.stringValue, "pinned-download")
    }

    /// An update whose install record cannot be written keeps the installed index and its record when another channel
    /// holds the pinned file, since the clone route must not remove the user's working copy either.
    func testFailedRecordDuringUpdateWithASiblingCopyKeepsTheInstalledIndex() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let served = try serve(pinned, as: "pinned.idx")
        let siblingRoot = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let previewRoot = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        let sibling = makeRegistry(spec: try spec(pinning: pinned, url: served), userRoot: siblingRoot)
        _ = try await sibling.installManagedDatabase(Self.databaseID, reinstall: true)
        let earlier = makeRegistry(
            spec: try spec(pinning: hostBuilt, url: try serve(hostBuilt, as: "host-built.idx")), userRoot: previewRoot
        )
        let installed = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let recordURL = installed.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let recordBefore = try Data(contentsOf: recordURL)
        let registry = makeRegistry(
            spec: try spec(pinning: pinned, url: served),
            userRoot: previewRoot,
            provenanceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            siblingDatabaseRoots: [siblingRoot]
        )

        do {
            _ = try await registry.updateManagedDatabase(Self.databaseID)
            XCTFail("The update succeeded without its record")
        } catch HumanScrubberDatabaseError.installationFailed(let databaseID, _, let reason) {
            XCTAssertEqual(databaseID, Self.databaseID)
            XCTAssertTrue(reason.contains("managed database install provenance"), reason)
        }
        XCTAssertEqual(try Data(contentsOf: installed), hostBuilt)
        XCTAssertEqual(try Data(contentsOf: recordURL), recordBefore)
        XCTAssertEqual(
            regularFileNames(under: installed.deletingLastPathComponent()),
            [ProvenanceRecorder.provenanceFilename, "ribokmers.k31w15.idx"].sorted()
        )
    }

    /// The bundled lock keeps how the hosted file was built as data, a one-thread build that two runs gave with
    /// equal digests.
    func testBundledLockKeepsTheHostedBuildProvenance() throws {
        let build = try XCTUnwrap(ManagedToolLock.bundled.database(id: Self.databaseID)?.build)
        XCTAssertEqual(build.tool, "deacon")
        XCTAssertEqual(build.toolVersion, "0.16.0")
        XCTAssertEqual(build.sourceUrl, "https://bbmap.org/resources/ribokmers.fa.gz")
        XCTAssertEqual(build.sourceSha256, "38607351140350d33c868919eb01aaa438c9b729470a094ab2eed55f8056fbf1")
        XCTAssertEqual(build.sourceSizeBytes, 9_548_991)
        XCTAssertEqual(build.argv, Self.buildArgv)
        XCTAssertEqual(build.byteReproducible, true)
        XCTAssertEqual(build.minimizerCount, 1_263_492)
        XCTAssertEqual(build.minimizerSetSha256, "65a92bbcfb88b4db2ed437c9d4a22e2751916dafa4a31cf8c167daeaa0242c05")
        XCTAssertEqual(
            build.minimizerSetMethod,
            "SHA-256 of the minimizers sorted ascending as 8-byte little-endian integers, the 11-byte header left out"
        )
        let note = try XCTUnwrap(build.note)
        XCTAssertTrue(note.contains("minimizer-set digest"), note)
        XCTAssertTrue(note.contains("one thread"), note)
    }

    /// A managed database whose lock row pins no hosted build has no update to apply. The registry says so and never
    /// falls back to a reinstall, which for `deacon-panhuman` would download 3.2 GB.
    func testUpdateOfADatabaseWithNoHostedBuildThrowsAndDownloadsNothing() async throws {
        let payload = Data("pinned-ribokmers-index\n".utf8)
        let requests = RibokmersSeamLog<URL>()
        let registry = makeRegistry(spec: try spec(pinning: payload, url: try serve(payload, as: "x.idx")), requests: requests)

        do {
            _ = try await registry.updateManagedDatabase("deacon-panhuman")
            XCTFail("The update reinstalled a database the lock pins no hosted build for")
        } catch HumanScrubberDatabaseError.installationFailed(let databaseID, _, let reason) {
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertTrue(reason.contains("pins no hosted build"), reason)
        }
        XCTAssertEqual(requests.values, [])
    }

    /// An index that holds the pinned build's minimizers in another order is a rebuild, and the status says so only
    /// after it has computed the set from the installed file.
    func testStatusCallsAReorderedCopyOfThePinnedIndexARebuild() async throws {
        let words: [UInt64] = [5, 90, 17, 1_000_000, 42]
        let pinned = Self.deaconIndex(words: words)
        let reordered = Self.deaconIndex(words: [1_000_000, 17, 5, 42, 90])
        let earlier = makeRegistry(spec: try spec(pinning: reordered, url: try serve(reordered, as: "reordered.idx")))
        _ = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let registry = makeRegistry(spec: try spec(
            pinning: pinned, url: try serve(pinned, as: "pinned.idx"), minimizerSet: (words.count, Self.setDigest(of: words))
        ))

        let status = try await registry.pinStatus(for: Self.databaseID)

        XCTAssertEqual(status, .rebuildOfPinnedBuild(
            installedSHA256: Self.sha256(reordered), pinnedSHA256: Self.sha256(pinned), minimizerCount: 5
        ))
        let summary = status.summary(databaseID: Self.databaseID)
        XCTAssertTrue(summary.contains("holds the same 5 minimizers as the pinned build in a different order"), summary)
        XCTAssertTrue(summary.contains("is a rebuild and filters the same reads"), summary)
        XCTAssertTrue(summary.contains("db update deacon-ribokmers --yes"), summary)
    }

    /// An index with one minimizer changed has the same size and is not called a rebuild.
    func testStatusStillCallsADifferentIndexDifferent() async throws {
        let words: [UInt64] = [5, 90, 17, 1_000_000, 42]
        let pinned = Self.deaconIndex(words: words)
        let changed = Self.deaconIndex(words: [5, 90, 17, 1_000_001, 42])
        XCTAssertEqual(pinned.count, changed.count)
        let earlier = makeRegistry(spec: try spec(pinning: changed, url: try serve(changed, as: "changed.idx")))
        _ = try await earlier.installManagedDatabase(Self.databaseID, reinstall: true)
        let registry = makeRegistry(spec: try spec(
            pinning: pinned, url: try serve(pinned, as: "pinned.idx"), minimizerSet: (words.count, Self.setDigest(of: words))
        ))

        let status = try await registry.pinStatus(for: Self.databaseID)

        XCTAssertEqual(status, .differsFromPin(installedSHA256: Self.sha256(changed), pinnedSHA256: Self.sha256(pinned)))
        XCTAssertTrue(status.summary(databaseID: Self.databaseID).contains("differs from the pinned build"))
    }

    // MARK: - Helpers

    /// A Deacon index: the 11-byte header (format 3, k 31, w 15, a little-endian count) and the 8-byte words.
    static func deaconIndex(words: [UInt64]) -> Data {
        var data = Data([3, 31, 15])
        for value in [UInt64(words.count)] + words {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The set digest the lock records, computed here by the method the lock states and not by the code under test.
    static func setDigest(of words: [UInt64]) -> String {
        var data = Data()
        for value in words.sorted() {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return sha256(data)
    }

    private static let buildArgv = [
        "deacon", "index", "build", "-k", "31", "-w", "15", "ribokmers.fa.gz", "-o", "ribokmers.k31w15.idx", "-t", "1",
    ]

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `data` to a file the download seam serves by its file URL.
    func serve(_ data: Data, as name: String) throws -> URL {
        let directory = tempDir.appendingPathComponent("served", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Fixed strings the fixture's lock row carries for the build facts beyond the argv, so a test can tell that the
    /// install record copied them from the lock.
    static let fixtureMinimizerSetMethod = "fixture method: SHA-256 of the sorted little-endian minimizers"
    static let fixtureBuildNote = "fixture note: a one-thread build"

    /// The lock entry of a hosted ribokmers build that pins `payload` and names `url` as its download. The row carries
    /// `byteReproducible`, the set method and the note, and the minimizer count and set digest when `minimizerSet` is given.
    func spec(pinning payload: Data, url: URL, minimizerSet: (count: Int, sha256: String)? = nil) throws -> DatabaseSpec {
        var build: [String: Any] = [
            "tool": "deacon", "toolVersion": "0.16.0", "sourceUrl": "https://bbmap.org/resources/ribokmers.fa.gz",
            "sourceSha256": String(repeating: "a", count: 64), "sourceSizeBytes": 12, "argv": Self.buildArgv,
            "byteReproducible": true, "minimizerSetMethod": Self.fixtureMinimizerSetMethod, "note": Self.fixtureBuildNote,
        ]
        if let minimizerSet {
            build["minimizerCount"] = minimizerSet.count
            build["minimizerSetSha256"] = minimizerSet.sha256
        }
        let json: [String: Any] = [
            "id": Self.databaseID, "sourcePolicy": "pinnedArchive", "tool": "deacon",
            "displayName": "Ribosomal RNA Removal Data", "version": "fixture-1", "filename": "ribokmers.k31w15.idx",
            "indexFormat": 3, "url": url.absoluteString, "sizeBytes": payload.count, "sha256": Self.sha256(payload),
            "build": build,
        ]
        return try JSONDecoder().decode(DatabaseSpec.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A registry rooted under the test folder whose lock lookup returns `spec`, whose downloader copies a file URL
    /// and logs it, and whose tool runner logs any tool and fails it.
    func makeRegistry(
        spec: DatabaseSpec,
        userRoot: URL? = nil,
        requests: RibokmersSeamLog<URL>? = nil,
        tools: RibokmersSeamLog<String>? = nil,
        downloader: ManagedDatabaseDownloader? = nil,
        provenanceWriter: ManagedDatabaseProvenanceWriter? = nil,
        siblingDatabaseRoots: [URL] = []
    ) -> DatabaseRegistry {
        let downloads = tempDir.appendingPathComponent("downloads", isDirectory: true)
        let fileDownloader: ManagedDatabaseDownloader = { url, progress in
            requests?.append(url)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let output = downloads.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: output)
            let size = Int64(try Data(contentsOf: output).count)
            progress(1.0, size, size)
            return ManagedDatabaseDownloadResult(fileURL: output, wallTime: 0.125)
        }
        let toolRunner: ManagedDatabaseToolRunner = { name, arguments, _, _, _ in
            tools?.append(([name] + arguments).joined(separator: " "))
            return ManagedDatabaseToolResult(stdout: "", stderr: "no tool may run", exitCode: 1, wallTime: 0)
        }
        let pinned = spec
        return DatabaseRegistry(
            bundledDatabasesRoot: tempDir.appendingPathComponent("bundled-databases", isDirectory: true),
            userDatabasesRoot: userRoot ?? tempDir.appendingPathComponent("user-databases", isDirectory: true),
            managedDatabaseDownloader: downloader ?? fileDownloader,
            managedDatabaseToolRunner: toolRunner,
            managedDatabaseLockLookup: { $0 == Self.databaseID ? pinned : nil },
            managedDatabaseProvenanceWriter: provenanceWriter,
            preferences: preferencesSuite.makeDefaults(),
            siblingDatabaseRoots: siblingDatabaseRoots
        )
    }

    func installRecord(beside installed: URL) throws -> WorkflowRun {
        let url = installed.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: url)).legacyWorkflowRun()
    }

    func regularFileNames(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var names: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(url.lastPathComponent)
            }
        }
        return names.sorted()
    }
}

/// What a seam was asked for, readable after the install.
final class RibokmersSeamLog<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
}
