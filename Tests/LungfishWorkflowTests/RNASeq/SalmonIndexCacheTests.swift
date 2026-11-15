// SalmonIndexCacheTests.swift - The one owner of the salmon index cache (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

final class SalmonIndexCacheTests: XCTestCase {
    var base: URL!
    var root: URL!
    var capture: URL!
    var stand: ManagedTestStandIn!

    static let route = "LGE does not build this index on Linux yet: run salmon there, or nf-core/rnaseq, and bring its "
        + "salmon folders into a project with lungfish-cli import rnaseq"
    static let roomy = RunFitHostFacts(physicalMemoryBytes: 68_719_476_736)

    /// A stand-in for salmon 2.x. `--version` prints the version the test set. `index` logs its arguments, keeps a copy
    /// of the gentrome and the decoy list, and writes `info.json` and two files in the `-i` folder. `badk` makes its
    /// `info.json` say k 25, and `compete` moves a whole published folder to the final path before it exits.
    static func salmonScript(capture: URL) -> String {
        let c = capture.path
        return """
        #!/bin/sh
        echo "$*" >> "\(c)/log"
        case "$1" in
          --version) echo "salmon $(/bin/cat "\(c)/version")"; exit 0 ;;
          index) shift ;;
          *) exit 2 ;;
        esac
        t=""; d=""; i=""; k=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -t) t="$2"; shift 2 ;;
            -d) d="$2"; shift 2 ;;
            -i) i="$2"; shift 2 ;;
            -k) k="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        /bin/cp "$t" "\(c)/gentrome.fa"
        /bin/mkdir -p "$i"
        n=0
        decoy=""
        if [ -n "$d" ]; then
          /bin/cp "$d" "\(c)/decoys.txt"
          n=$(/usr/bin/grep -c . "$d")
          decoy=', "decoy_seq_hash": "dseq1", "decoy_name_hash": "dname1"'
        fi
        [ -f "\(c)/badk" ] && k=25
        printf '{"k": %s, "salmon_version": "%s", "num_decoys": %s, "seq_hash": "seq1", "name_hash": "name1"%s}\\n' \\
          "$k" "$(/bin/cat "\(c)/version")" "$n" "$decoy" > "$i/info.json"
        echo x > "$i/refseq.bin"
        echo y > "$i/index.ssi"
        if [ -f "\(c)/compete" ]; then
          stage=$(/usr/bin/dirname "$i")
          name=$(/usr/bin/basename "$stage")
          name=${name#.}
          name=${name%%.creating-*}
          /bin/mv "\(c)/competitor" "$(/usr/bin/dirname "$stage")/$name"
        fi
        exit 0
        """
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("salmon-index-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        capture = base.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        stand = try ManagedTestStandIn(prefix: "salmon-index-home")
        try stand.install("salmon", script: Self.salmonScript(capture: capture))
        try setVersion("2.11.0")
    }

    override func tearDownWithError() throws {
        stand?.remove()
        try? FileManager.default.removeItem(at: base)
    }

    /// Writes the environment's package record, which the cache reads with no process, and the version the stand-in prints.
    func setVersion(_ version: String) throws {
        let meta = stand.home.appendingPathComponent(".lungfish/conda/envs/salmon/conda-meta", isDirectory: true)
        try? FileManager.default.removeItem(at: meta)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"name":"salmon","version":"\#(version)","build":"h0_0"}"#.utf8)
            .write(to: meta.appendingPathComponent("salmon-\(version)-h0_0.json"))
        try Data(version.utf8).write(to: capture.appendingPathComponent("version"))
    }

    func makeSet(release: String = "7") async throws -> ReferenceSetOutcome {
        let inputs = base.appendingPathComponent("inputs-\(release)", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data(ReferenceSetOwnerTests.genome.utf8).write(to: inputs.appendingPathComponent("genome.fa"))
        try Data(ReferenceSetOwnerTests.annotation.utf8).write(to: inputs.appendingPathComponent("genes.gtf"))
        let request = ReferenceSetRequest(
            name: "Test set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB",
            annotationRelease: release, genome: inputs.appendingPathComponent("genome.fa"),
            annotation: inputs.appendingPathComponent("genes.gtf"), extras: [], layout: .lge)
        let owner = ReferenceSetOwner(
            storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    func cache(host: RunFitHostFacts = SalmonIndexCacheTests.roomy, free: Int64 = 1_000_000_000_000) -> SalmonIndexCache {
        SalmonIndexCache(
            storageRoot: root,
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: stand.home, appIdentity: .preview),
            provenanceWriter: ProvenanceWriter(signingProvider: nil), host: host, freeSpace: { _ in free })
    }

    func ensure(_ request: SalmonIndexRequest, host: RunFitHostFacts = SalmonIndexCacheTests.roomy,
                free: Int64 = 1_000_000_000_000) async throws -> SalmonIndexOutcome {
        try await cache(host: host, free: free).ensure(request, linuxRoute: Self.route, argv: ["lungfish-cli", "rnaseq", "index"])
    }

    /// Each line the stand-in logged, one a run.
    func log() -> [String] {
        let text = (try? String(contentsOf: capture.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func indexRuns() -> Int { log().filter { $0.hasPrefix("index ") }.count }

    func setFolder(_ id: String) -> URL {
        root.appendingPathComponent("\(SalmonIndexCache.folderName)/\(id)", isDirectory: true)
    }

    func entries(_ folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A result folder whose record holds the hashes given, as a quantification's record names its index.
    @discardableResult
    func result(_ name: String, naming hashes: [String]) throws -> URL {
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "{\"index\": [" + hashes.map { "\"\($0)\"" }.joined(separator: ", ") + "]}\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent(".lungfish-provenance.json"))
        return folder
    }

    static let builtHashes = ["seq1", "name1", "dseq1", "dname1"]

    // MARK: - Row 1, key and reuse

    func testASecondRequestOfTheSameKeyReusesTheIndexAndStartsNoSalmon() async throws {
        let set = try await makeSet()
        let first = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        let second = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.hashes, first.hashes)
        XCTAssertEqual(first.url.lastPathComponent, "salmon-2.11.0-k31-genome-decoys")
        XCTAssertEqual(indexRuns(), 1, "the second request starts no salmon index")
        XCTAssertFalse(log().contains { $0.contains("--version") }, "the version comes from the environment, not a process")
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [first.url.lastPathComponent])
    }

    func testAChangedSetSalmonVersionKOrDecoysMakesANewFolder() async throws {
        let set = try await makeSet()
        let other = try await makeSet(release: "8")
        XCTAssertNotEqual(set.manifest.id, other.manifest.id)
        var folders = Set<URL>()
        folders.insert(try await ensure(SalmonIndexRequest(setID: set.manifest.id)).url)
        folders.insert(try await ensure(SalmonIndexRequest(setID: other.manifest.id)).url)
        folders.insert(try await ensure(SalmonIndexRequest(setID: set.manifest.id, k: 25)).url)
        folders.insert(try await ensure(SalmonIndexRequest(setID: set.manifest.id, decoys: .none)).url)
        try setVersion("2.12.0")
        let newer = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        folders.insert(newer.url)
        XCTAssertEqual(folders.count, 5)
        XCTAssertEqual(indexRuns(), 5)
        XCTAssertEqual(newer.url.lastPathComponent, "salmon-2.12.0-k31-genome-decoys")
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [
            "salmon-2.11.0-k25-genome-decoys", "salmon-2.11.0-k31-genome-decoys", "salmon-2.11.0-k31-no-decoys",
            "salmon-2.12.0-k31-genome-decoys",
        ])
    }

    func testABuildThatLosesTheRenameRemovesItsStageAndReturnsThePublishedIndex() async throws {
        let set = try await makeSet()
        let first = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        try FileManager.default.moveItem(at: first.url, to: capture.appendingPathComponent("competitor"))
        try Data().write(to: capture.appendingPathComponent("compete"))
        let second = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.hashes, first.hashes)
        XCTAssertEqual(indexRuns(), 2)
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [first.url.lastPathComponent], "no stage is left")
    }

    // MARK: - Row 2, cleanup

    func testAUseFileIsWrittenOnceAndNeverRewritten() async throws {
        let outcome = try await ensure(SalmonIndexRequest(setID: try await makeSet().manifest.id))
        let folder = try result("quant", naming: Self.builtHashes)
        let use = try cache().recordUse(of: outcome, resultFolder: folder)
        XCTAssertEqual(use.deletingLastPathComponent(), outcome.url.appendingPathComponent("uses", isDirectory: true))
        let bytes = try Data(contentsOf: use)
        let modified = try FileManager.default.attributesOfItem(atPath: use.path)[.modificationDate] as? Date
        try result("quant", naming: ["other"])
        let again = try cache().recordUse(of: outcome, resultFolder: folder)
        XCTAssertEqual(again, use)
        XCTAssertEqual(try Data(contentsOf: use), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: use.path)[.modificationDate] as? Date, modified)
    }

    func testRemovingAnIndexWhileAUsesResultNamesItsHashesIsRefusedInWordsThatNameTheResult() async throws {
        let outcome = try await ensure(SalmonIndexRequest(setID: try await makeSet().manifest.id))
        let folder = try result("quant", naming: Self.builtHashes)
        try cache().recordUse(of: outcome, resultFolder: folder)
        XCTAssertThrowsError(try cache().remove(outcome.key)) { error in
            XCTAssertTrue(error.localizedDescription.contains(folder.path), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.indexURL.appendingPathComponent("info.json").path))
    }

    func testAUseWhoseResultIsGoneOrWhoseRecordNamesOtherHashesHoldsNothing() async throws {
        let set = try await makeSet()
        let gone = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        let renamed = try await ensure(SalmonIndexRequest(setID: set.manifest.id, k: 25))
        let goneFolder = try result("quant-gone", naming: Self.builtHashes)
        try cache().recordUse(of: gone, resultFolder: goneFolder)
        try FileManager.default.removeItem(at: goneFolder)
        let otherFolder = try result("quant-other", naming: Self.builtHashes)
        try cache().recordUse(of: renamed, resultFolder: otherFolder)
        try result("quant-other", naming: ["seq9", "name9", "dseq9", "dname9"])

        try cache().remove(gone.key)
        try cache().remove(renamed.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setFolder(set.manifest.id).path), "an empty set folder goes too")
    }

    func testLaunchCleanupLeavesBothFoldersWhole() async throws {
        let manager = TempFileManager(appIdentity: .debug, temporaryDirectory: base.appendingPathComponent("tmp", isDirectory: true))
        let temporary = manager.temporaryRootURL
        let sets = temporary.appendingPathComponent("\(ReferenceSetOwner.folderName)/x.lungfishrefset", isDirectory: true)
        let stage = temporary.appendingPathComponent(
            "\(SalmonIndexCache.folderName)/x/.salmon-2.11.0-k31-genome-decoys.creating-\(UUID().uuidString)", isDirectory: true)
        let extract = temporary.appendingPathComponent("lungfish-extract-x", isDirectory: true)
        for folder in [sets, stage, extract] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("kept\n".utf8).write(to: folder.appendingPathComponent("file"))
        }
        await manager.setMaxAge(hours: 0)
        await manager.cleanupOnLaunch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sets.appendingPathComponent("file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extract.path), "launch cleanup still removes its own folders")
    }

    func testAStageLeftByACrashGoesBeforeABuildAndAHeldStageStays() async throws {
        let set = try await makeSet()
        let folder = setFolder(set.manifest.id)
        let crashed = folder.appendingPathComponent(".salmon-2.10.0-k31-genome-decoys.creating-\(UUID().uuidString)", isDirectory: true)
        let held = folder.appendingPathComponent(".salmon-2.11.0-k31-no-decoys.creating-\(UUID().uuidString)", isDirectory: true)
        let notes = folder.appendingPathComponent("notes", isDirectory: true)
        for stage in [crashed, held, notes] {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        }
        // A running build holds its stage with an exclusive flock on the folder.
        let descriptor = open(held.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { close(descriptor) }

        let outcome = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        XCTAssertEqual(try entries(folder), [held.lastPathComponent, "notes", outcome.url.lastPathComponent].sorted())
    }

    // MARK: - The need, before any process (not failing first)

    func testAHostWithLessMemoryThanTheIndexNeedsIsRefusedBeforeSalmonStarts() async throws {
        let set = try await makeSet()
        do {
            _ = try await ensure(SalmonIndexRequest(setID: set.manifest.id), host: RunFitHostFacts(physicalMemoryBytes: 17_179_869_184))
            XCTFail("a 16 GB Mac builds no index")
        } catch let error as RunFitError {
            guard case .insufficientMemory = error else { return XCTFail("\(error)") }
            let words = error.localizedDescription
            for part in ["16.56 GB", "16 GB", "17 GB", "lungfish-cli import rnaseq"] {
                XCTAssertTrue(words.contains(part), "\(part) is missing from: \(words)")
            }
        }
        XCTAssertEqual(log(), [], "no salmon process starts")
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [], "no stage is made")
        let roomier = try await ensure(SalmonIndexRequest(setID: set.manifest.id), host: RunFitHostFacts(physicalMemoryBytes: 19_327_352_832))
        XCTAssertFalse(roomier.reused)
    }

    func testAVolumeWithTooLittleFreeDiskIsRefusedBeforeSalmonStarts() async throws {
        let set = try await makeSet()
        do {
            _ = try await ensure(SalmonIndexRequest(setID: set.manifest.id), free: 1_000_000_000)
            XCTFail("a volume with 1 GB free builds no index")
        } catch let error as RunFitError {
            guard case .insufficientDisk = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("lungfish-cli import rnaseq"))
        }
        XCTAssertEqual(log(), [])
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [])
    }

    // MARK: - What a build writes (not failing first)

    func testTheGentromeDecoysArgvAndKeyFileAreWhatTheScriptsWrite() async throws {
        let set = try await makeSet()
        let outcome = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        let transcripts = try Data(contentsOf: set.url.appendingPathComponent("derived/transcripts.fa"))
        XCTAssertEqual(try Data(contentsOf: capture.appendingPathComponent("gentrome.fa")),
                       transcripts + Data(ReferenceSetOwnerTests.genome.utf8))
        XCTAssertEqual(try String(contentsOf: capture.appendingPathComponent("decoys.txt"), encoding: .utf8), "chr1\nMT\n")
        let argv = try XCTUnwrap(log().first).split(separator: " ").map(String.init)
        XCTAssertEqual(argv.count, 12)
        XCTAssertEqual([argv[0], argv[1], argv[3]], ["index", "-t", "-d"])
        XCTAssertEqual(Array(argv[5...]).dropLast(), ["-k", "31", "-p", "8", "--ramLimit", "4", "-i"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent(".work").path))

        let key = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: outcome.url.appendingPathComponent("index-key.json"))) as? [String: Any])
        XCTAssertEqual(key["setID"] as? String, set.manifest.id)
        XCTAssertEqual(key["salmonVersion"] as? String, "2.11.0")
        XCTAssertEqual(key["k"] as? Int, 31)
        XCTAssertEqual(key["decoys"] as? String, "genome-decoys")
        XCTAssertEqual(key["salmonBuild"] as? String, "salmon-2.11.0-h0_0")
        XCTAssertEqual(key["referenceSetSHA256"] as? String,
                       try ProvenanceFileHasher.sha256(of: set.url.appendingPathComponent(ReferenceSetManifest.filename)))
        XCTAssertEqual(key["argv"] as? [String], [
            "salmon", "index", "-t", "gentrome.fa", "-d", "decoys.txt", "-k", "31", "-p", "8", "--ramLimit", "4", "-i", "index",
        ])
        XCTAssertEqual([key["index_seq_hash"], key["index_name_hash"], key["index_decoy_seq_hash"], key["index_decoy_name_hash"]]
            .compactMap { $0 as? String }, Self.builtHashes)
        let record = try String(contentsOf: outcome.url.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(record.contains("salmon"))
        for hash in Self.builtHashes { XCTAssertTrue(record.contains(hash), "the record names \(hash)") }
    }

    func testANoDecoysBuildPassesNoDecoyList() async throws {
        let set = try await makeSet()
        _ = try await ensure(SalmonIndexRequest(setID: set.manifest.id, decoys: .none))
        XCTAssertFalse(try XCTUnwrap(log().first).contains(" -d "))
        XCTAssertEqual(try Data(contentsOf: capture.appendingPathComponent("gentrome.fa")),
                       try Data(contentsOf: set.url.appendingPathComponent("derived/transcripts.fa")))
    }

    func testAnInfoFileThatDisagreesWithTheKeyPublishesNothing() async throws {
        let set = try await makeSet()
        try Data().write(to: capture.appendingPathComponent("badk"))
        do {
            _ = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
            XCTFail("an index of k 25 is not published as k 31")
        } catch let error as SalmonIndexError {
            XCTAssertTrue(error.localizedDescription.contains("k"), error.localizedDescription)
        }
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [])
    }
}
