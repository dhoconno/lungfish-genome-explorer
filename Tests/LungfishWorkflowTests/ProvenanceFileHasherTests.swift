import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Provenance File Hasher")
struct ProvenanceFileHasherTests {
    @Test("computes full SHA-256 and byte size descriptors")
    func computesFullSHA256AndByteSizeDescriptors() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fastqURL = directory.appendingPathComponent("reads.fastq")
        let contents = "@read1\nACGTACGT\n+\nFFFFFFFF\n"
        try contents.write(to: fastqURL, atomically: true, encoding: .utf8)

        let descriptor = try ProvenanceFileDescriptor.file(
            url: fastqURL,
            format: .fastq,
            role: .input,
            originPath: "/source/reads.fastq",
            sourceProvenancePath: "/source/.lungfish-provenance.json"
        )

        #expect(try ProvenanceFileHasher.sha256(of: fastqURL) == "363ab6eaaefd9621dfbc46f600ab919e97c0e4d33c5a92e3d462384f424cee71")
        #expect(try ProvenanceFileHasher.fileSize(of: fastqURL) == 27)
        #expect(descriptor.path == fastqURL.path)
        #expect(descriptor.checksumSHA256 == "363ab6eaaefd9621dfbc46f600ab919e97c0e4d33c5a92e3d462384f424cee71")
        #expect(descriptor.fileSize == 27)
        #expect(descriptor.format == .fastq)
        #expect(descriptor.role == .input)
        #expect(descriptor.originPath == "/source/reads.fastq")
        #expect(descriptor.sourceProvenancePath == "/source/.lungfish-provenance.json")
    }

    @Test("recorder SHA-256 uses full file hashing for large files")
    func recorderSHA256UsesFullFileHashingForLargeFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let largeURL = directory.appendingPathComponent("large.bin")
        try makeSparseLargeFile(at: largeURL)

        let expectedFullSHA256 = "b30d77642e38b3a5bc7e3a31d9c6df600d1175cfb3d299b2eb2f6a0613e8182e"
        let hasherDigest = try ProvenanceFileHasher.sha256(of: largeURL)
        let recorderDigest = try #require(ProvenanceRecorder.sha256(of: largeURL))

        #expect(try ProvenanceFileHasher.fileSize(of: largeURL) == 104_857_601)
        #expect(hasherDigest == expectedFullSHA256)
        #expect(recorderDigest == expectedFullSHA256)
        #expect(!hasherDigest.hasPrefix("partial:"))
        #expect(!recorderDigest.hasPrefix("partial:"))
    }

    @Test("directory manifest records deterministic visible regular files")
    func directoryManifestRecordsDeterministicVisibleRegularFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nestedDirectory = directory.appendingPathComponent("nested")
        let hiddenDirectory = directory.appendingPathComponent(".hidden-directory")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try "beta\n".write(to: nestedDirectory.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try "alpha\n".write(to: directory.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "root secret\n".write(to: directory.appendingPathComponent(".secret.txt"), atomically: true, encoding: .utf8)
        try "nested secret\n".write(to: nestedDirectory.appendingPathComponent(".nested-secret.txt"), atomically: true, encoding: .utf8)
        try "hidden child\n".write(to: hiddenDirectory.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        let manifest = try ProvenanceFileHasher.directoryManifest(for: directory)

        #expect(manifest.rootPath == directory.path)
        #expect(manifest.files.map(\.path) == ["alpha.txt", "nested/beta.txt"])
        #expect(manifest.files.map(\.fileSize) == [6, 5])
        #expect(manifest.files.allSatisfy { $0.checksumSHA256?.count == 64 })
        #expect(manifest.files.allSatisfy { !$0.path.split(separator: "/").contains { $0.hasPrefix(".") } })
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("provenance-file-hasher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeSparseLargeFile(at url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: Data("LF".utf8))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 104_857_601)
    try handle.seek(toOffset: 104_857_600)
    try handle.write(contentsOf: Data([0x21]))
}
