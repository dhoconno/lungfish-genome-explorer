import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishKit
import LungfishTestSupport

/// The data key builders of VS B1. Every file here lives under `TestTempDirectory`.
final class ViewMemoryDataKeyTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "view-memory-key")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        return folder
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func makeManifest(
        identifier: String = "org.test.ref",
        name: String = "Reference",
        md5: String? = "abc123",
        chromosomes: [(String, Int64)] = [("chr1", 1_000), ("chr2", 500)],
        annotations: [AnnotationTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = []
    ) -> BundleManifest {
        BundleManifest(
            name: name,
            identifier: identifier,
            source: SourceInfo(organism: "Test organism", assembly: "T1"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: chromosomes.reduce(Int64(0)) { $0 + $1.1 },
                chromosomes: chromosomes.map {
                    ChromosomeInfo(name: $0.0, length: $0.1, offset: 0, lineBases: 60, lineWidth: 61)
                },
                md5Checksum: md5
            ),
            annotations: annotations,
            alignments: alignments
        )
    }

    private func annotationTrack(id: String = "genes", path: String = "annotations/genes.db") -> AnnotationTrackInfo {
        AnnotationTrackInfo(id: id, name: id, path: "annotations/\(id).bb", databasePath: path)
    }

    private func alignmentTrack(
        id: String = "aln1",
        path: String = "alignments/a.bam",
        reads: Int64? = 100
    ) -> AlignmentTrackInfo {
        AlignmentTrackInfo(id: id, name: id, sourcePath: path, indexPath: "\(path).bai", mappedReadCount: reads)
    }

    // MARK: - Reference

    func testAReferenceKeyIsStableAcrossBuildsAndIgnoresTheDisplayName() throws {
        let folder = try makeFolder()
        try write("db", to: folder.appendingPathComponent("annotations/genes.db"))
        let manifest = makeManifest(annotations: [annotationTrack()])
        let first = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first, ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder))
        let renamed = makeManifest(name: "Renamed", annotations: [annotationTrack()])
        XCTAssertEqual(first, ViewMemoryDataKey.reference(manifest: renamed, bundleURL: folder))
    }

    func testAReferenceKeyChangesWithTheIdentifierTheMd5TheSequencesAndTheTracks() throws {
        let folder = try makeFolder()
        try write("db", to: folder.appendingPathComponent("annotations/genes.db"))
        let base = ViewMemoryDataKey.reference(manifest: makeManifest(annotations: [annotationTrack()]), bundleURL: folder)
        let changed: [BundleManifest] = [
            makeManifest(identifier: "org.test.other", annotations: [annotationTrack()]),
            makeManifest(md5: "other", annotations: [annotationTrack()]),
            makeManifest(md5: nil, annotations: [annotationTrack()]),
            makeManifest(chromosomes: [("chr1", 1_001), ("chr2", 500)], annotations: [annotationTrack()]),
            makeManifest(chromosomes: [("chr1", 1_000)], annotations: [annotationTrack()]),
            makeManifest(chromosomes: [("chr2", 500), ("chr1", 1_000)], annotations: [annotationTrack()]),
            makeManifest(annotations: []),
            makeManifest(annotations: [annotationTrack(id: "genes2")]),
        ]
        for manifest in changed {
            let key = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
            XCTAssertFalse(base.matches(key), "\(manifest.identifier) \(String(describing: manifest.genome?.md5Checksum))")
        }
    }

    func testAReferenceKeyChangesWhenAnAnnotationDatabaseIsEdited() throws {
        let folder = try makeFolder()
        let database = folder.appendingPathComponent("annotations/genes.db")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try write("db", to: database, modified: past)
        let manifest = makeManifest(annotations: [annotationTrack()])
        let before = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)

        try write("db with one more feature", to: database, modified: past)
        let afterSizeChange = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
        XCTAssertFalse(before.matches(afterSizeChange), "an edit that changes the size changes the key")

        try write("db with one more feature", to: database, modified: past.addingTimeInterval(60))
        let afterDateChange = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
        XCTAssertFalse(afterSizeChange.matches(afterDateChange), "an edit that changes the date changes the key")
    }

    func testAMissingAnnotationDatabaseLeavesThePartUnreadSoTheKeyNeverMatches() throws {
        let folder = try makeFolder()
        let manifest = makeManifest(annotations: [annotationTrack()])
        let key = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
        XCTAssertFalse(key.isComplete)
        XCTAssertFalse(key.matches(key))
        XCTAssertNotEqual(key, key)
    }

    // MARK: - Mapping

    func testAMappingKeyTakesTheAlignmentTracksFromTheManifestWithTheFileSizeAndDate() throws {
        let folder = try makeFolder()
        let bam = folder.appendingPathComponent("alignments/a.bam")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try write("bam", to: bam, modified: past)
        let manifest = makeManifest(alignments: [alignmentTrack()])
        let base = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        XCTAssertTrue(base.isComplete)
        XCTAssertEqual(base.family, "mapping")
        XCTAssertTrue(base.parts.contains { $0.name == "alignments" })
        XCTAssertEqual(base, ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder))

        let otherReads = makeManifest(alignments: [alignmentTrack(reads: 101)])
        XCTAssertNotEqual(base, ViewMemoryDataKey.mapping(manifest: otherReads, bundleURL: folder))

        let otherID = makeManifest(alignments: [alignmentTrack(id: "aln2")])
        XCTAssertNotEqual(base, ViewMemoryDataKey.mapping(manifest: otherID, bundleURL: folder))

        try write("bam", to: folder.appendingPathComponent("alignments/b.bam"), modified: past)
        let otherPath = makeManifest(alignments: [alignmentTrack(path: "alignments/b.bam")])
        XCTAssertNotEqual(base, ViewMemoryDataKey.mapping(manifest: otherPath, bundleURL: folder))

        try write("bam rerun with more reads", to: bam, modified: past)
        XCTAssertNotEqual(base, ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder), "a rerun that replaces the file changes the key")

        try write("bam rerun with more reads", to: bam, modified: past.addingTimeInterval(5))
        let touched = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        try write("bam rerun with more reads", to: bam, modified: past.addingTimeInterval(9))
        XCTAssertNotEqual(touched, ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder), "the modification date counts")
    }

    func testAMappingKeyIsNeverAReferenceKeyOfTheSameManifest() throws {
        let folder = try makeFolder()
        try write("bam", to: folder.appendingPathComponent("alignments/a.bam"))
        let manifest = makeManifest(alignments: [alignmentTrack()])
        let reference = ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder)
        let mapping = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        XCTAssertNotEqual(reference, mapping)
    }

    func testAMissingAlignmentFileLeavesTheAlignmentPartUnread() throws {
        let folder = try makeFolder()
        let manifest = makeManifest(alignments: [alignmentTrack()])
        let key = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        XCTAssertFalse(key.isComplete)
        XCTAssertNil(key.parts.first { $0.name == "alignments" }?.value)
        XCTAssertNotNil(key.parts.first { $0.name == "identifier" }?.value, "the other parts were read")
        XCTAssertFalse(key.matches(key))
    }

    func testTheKeyNeverReadsFileContentOnlyTheDirectoryEntry() throws {
        let folder = try makeFolder()
        let bam = folder.appendingPathComponent("alignments/a.bam")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        try write("aaaaa", to: bam, modified: fixed)
        let manifest = makeManifest(alignments: [alignmentTrack()])
        let before = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        try write("bbbbb", to: bam, modified: fixed)
        let after = ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder)
        XCTAssertEqual(before, after, "same size and date, other content, so no hash of the file was taken")
    }

    // MARK: - Unread parts

    func testAKeyPartNotReadYetNeverComparesEqual() throws {
        let unread = ViewMemoryDataKey.unread(family: "reference", partNames: ["identifier", "sequences"])
        XCTAssertFalse(unread.isComplete)
        XCTAssertFalse(unread.matches(unread))
        XCTAssertNotEqual(unread, unread)

        let complete = ViewMemoryDataKey(family: "reference", parts: [.init(name: "identifier", value: "x")])
        XCTAssertEqual(complete, complete)
        XCTAssertNotEqual(complete, unread)
        XCTAssertFalse(ViewMemoryDataKey(family: "reference", parts: []).isComplete, "a key with no part proves nothing")

        let decoded = try JSONDecoder().decode(ViewMemoryDataKey.self, from: JSONEncoder().encode(unread))
        XCTAssertEqual(decoded.parts.map(\.name), ["identifier", "sequences"])
        XCTAssertFalse(decoded.isComplete, "the unread state survives encoding")
        let decodedComplete = try JSONDecoder().decode(ViewMemoryDataKey.self, from: JSONEncoder().encode(complete))
        XCTAssertEqual(decodedComplete, complete)
    }

    // MARK: - Analyses

    func testAnAnalysisKeyPrefersTheProvenanceEnvelopeThenTheManifestDateThenTheFileList() {
        let first = UUID()
        let second = UUID()
        let files = [ViewMemoryFileEntry(path: "a.tsv", size: 10)]
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let byEnvelope = ViewMemoryDataKey.analysis(provenanceEnvelopeID: first, manifestModifiedDate: date, files: files)
        XCTAssertEqual(byEnvelope, ViewMemoryDataKey.analysis(provenanceEnvelopeID: first, manifestModifiedDate: nil, files: []))
        XCTAssertNotEqual(
            byEnvelope,
            ViewMemoryDataKey.analysis(provenanceEnvelopeID: second, manifestModifiedDate: date, files: files),
            "a rerun writes a new record and changes the key"
        )

        let byDate = ViewMemoryDataKey.analysis(provenanceEnvelopeID: nil, manifestModifiedDate: date, files: files)
        XCTAssertEqual(byDate, ViewMemoryDataKey.analysis(provenanceEnvelopeID: nil, manifestModifiedDate: date, files: []))
        XCTAssertNotEqual(
            byDate,
            ViewMemoryDataKey.analysis(provenanceEnvelopeID: nil, manifestModifiedDate: date.addingTimeInterval(1), files: files)
        )

        let byFiles = ViewMemoryDataKey.analysis(provenanceEnvelopeID: nil, manifestModifiedDate: nil, files: files)
        XCTAssertEqual(byFiles, ViewMemoryDataKey.analysis(provenanceEnvelopeID: nil, manifestModifiedDate: nil, files: files))
        XCTAssertNotEqual(
            byFiles,
            ViewMemoryDataKey.analysis(
                provenanceEnvelopeID: nil,
                manifestModifiedDate: nil,
                files: [ViewMemoryFileEntry(path: "a.tsv", size: 11)]
            ),
            "an edit that changes a size changes the key"
        )

        XCTAssertNotEqual(byEnvelope, byDate)
        XCTAssertNotEqual(byDate, byFiles)
        XCTAssertNotEqual(byEnvelope, byFiles)
    }

    func testTheFileListIgnoresTheOrderOfTheEntries() {
        let one = ViewMemoryFileEntry(path: "a", size: 1)
        let two = ViewMemoryFileEntry(path: "b", size: 2)
        XCTAssertEqual(ViewMemoryDataKey.fileList([one, two]), ViewMemoryDataKey.fileList([two, one]))
    }

    func testAFileListFromAFolderChangesOnAnEditOrANewFileAndIgnoresHiddenFiles() throws {
        let folder = try makeFolder()
        try write("hello", to: folder.appendingPathComponent("a.txt"))
        let first = ViewMemoryDataKey.fileList(inFolder: folder)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first, ViewMemoryDataKey.fileList(inFolder: folder))

        try write("", to: folder.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(first, ViewMemoryDataKey.fileList(inFolder: folder), "a hidden file is not part of the result")

        try write("hello, edited", to: folder.appendingPathComponent("a.txt"))
        let edited = ViewMemoryDataKey.fileList(inFolder: folder)
        XCTAssertNotEqual(first, edited)

        try write("more", to: folder.appendingPathComponent("sub/b.txt"))
        XCTAssertNotEqual(edited, ViewMemoryDataKey.fileList(inFolder: folder))
    }

    func testAnUnreadableFolderGivesAnUnreadKey() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("view-memory-key-missing-\(UUID().uuidString)")
        let key = ViewMemoryDataKey.fileList(inFolder: missing)
        XCTAssertFalse(key.isComplete)
        XCTAssertFalse(key.matches(key))
    }

    func testAPathThatIsAFileGivesAnUnreadKey() throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("a.txt")
        try write("hello", to: file)
        XCTAssertNil(ViewMemoryFileEntry.entries(inFolder: file))
        XCTAssertFalse(ViewMemoryDataKey.fileList(inFolder: file).isComplete)
    }

    func testAFolderWithAnUnreadableSubfolderGivesAnUnreadKeyAndNotAListThatSkipsIt() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions")
        let folder = try makeFolder()
        try write("hello", to: folder.appendingPathComponent("a.txt"))
        let locked = folder.appendingPathComponent("locked")
        try write("inside", to: locked.appendingPathComponent("b.txt"))
        XCTAssertTrue(ViewMemoryDataKey.fileList(inFolder: folder).isComplete)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        let key = ViewMemoryDataKey.fileList(inFolder: folder)
        XCTAssertFalse(key.isComplete, "a list that skipped the folder would miss an edit inside it")
        XCTAssertFalse(key.matches(key))
    }

    func testAPayloadKeyChangesWithTheIdentifierTheRecordAndTheChecksums() {
        let base = ViewMemoryDataKey.payload(manifestIdentifier: "id", recordID: "r1", payloadChecksums: ["a": "1"])
        XCTAssertEqual(base, ViewMemoryDataKey.payload(manifestIdentifier: "id", recordID: "r1", payloadChecksums: ["a": "1"]))
        XCTAssertNotEqual(base, ViewMemoryDataKey.payload(manifestIdentifier: "other", recordID: "r1", payloadChecksums: ["a": "1"]))
        XCTAssertNotEqual(base, ViewMemoryDataKey.payload(manifestIdentifier: "id", recordID: "r2", payloadChecksums: ["a": "1"]))
        XCTAssertNotEqual(base, ViewMemoryDataKey.payload(manifestIdentifier: "id", recordID: "r1", payloadChecksums: ["a": "2"]))
        XCTAssertNotEqual(base, ViewMemoryDataKey.payload(manifestIdentifier: "id", recordID: nil, payloadChecksums: ["a": "1"]))
    }

    // MARK: - Off the main actor (SWIFT 2)

    func testTheBuildersRunFromADetachedTaskOffTheMainThread() async throws {
        let folder = try makeFolder()
        try write("db", to: folder.appendingPathComponent("annotations/genes.db"))
        try write("bam", to: folder.appendingPathComponent("alignments/a.bam"))
        let manifest = makeManifest(annotations: [annotationTrack()], alignments: [alignmentTrack()])

        let result = await Task.detached { () -> (onMain: Bool, reference: ViewMemoryDataKey, mapping: ViewMemoryDataKey, files: ViewMemoryDataKey) in
            let onMain = pthread_main_np() != 0
            return (
                onMain,
                ViewMemoryDataKey.reference(manifest: manifest, bundleURL: folder),
                ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: folder),
                ViewMemoryDataKey.fileList(inFolder: folder)
            )
        }.value

        XCTAssertFalse(result.onMain, "the builders must be callable from a task that is not on the main thread")
        XCTAssertTrue(result.reference.isComplete)
        XCTAssertTrue(result.mapping.isComplete)
        XCTAssertTrue(result.files.isComplete)
    }
}
