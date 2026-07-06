import Testing
import Foundation
@testable import LungfishCore

@Suite("BundleAttachmentStore")
struct BundleAttachmentStoreTests {

    @Test("Lists files from attachments directory")
    func listFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        let attachDir = tmp.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        let notesURL = attachDir.appendingPathComponent("notes.txt")
        try "hello".write(to: notesURL, atomically: true, encoding: .utf8)
        try "{}".write(
            to: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: notesURL),
            atomically: true,
            encoding: .utf8
        )

        let store = BundleAttachmentStore(bundleURL: tmp)
        store.reload()
        #expect(store.attachments.count == 1)
        #expect(store.attachments[0].filename == "notes.txt")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Attach file copies into bundle")
    func attachFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sourceFile = tmp.appendingPathComponent("source.txt")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        try store.attach(fileAt: sourceFile)
        #expect(store.attachments.count == 1)
        #expect(store.attachments[0].filename == "source.txt")
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Attaching removes stale provenance sidecar")
    func attachingRemovesStaleProvenanceSidecar() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sourceFile = tmp.appendingPathComponent("source.txt")
        try "old".write(to: sourceFile, atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        let attachedURL = store.urlForAttachment("source.txt")
        let sidecarURL = BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: attachedURL)
        try FileManager.default.createDirectory(at: store.attachmentsDirectory, withIntermediateDirectories: true)
        try "{}".write(to: sidecarURL, atomically: true, encoding: .utf8)

        try "new".write(to: sourceFile, atomically: true, encoding: .utf8)
        try store.attach(fileAt: sourceFile)

        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Failed replacement preserves existing attachment and provenance")
    func failedReplacementPreservesExistingAttachmentAndProvenance() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let attachDir = tmp.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)

        let existingURL = attachDir.appendingPathComponent("notes.txt")
        let sidecarURL = BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: existingURL)
        try "original".write(to: existingURL, atomically: true, encoding: .utf8)
        try "{\"status\":\"original\"}".write(to: sidecarURL, atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        let missingReplacement = tmp.appendingPathComponent("notes.txt")

        #expect(throws: (any Error).self) {
            try store.attach(fileAt: missingReplacement)
        }
        #expect((try? String(contentsOf: existingURL, encoding: .utf8)) == "original")
        #expect((try? String(contentsOf: sidecarURL, encoding: .utf8)) == "{\"status\":\"original\"}")
    }

    @Test("Remove attachment moves to trash")
    func removeAttachment() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        let attachDir = tmp.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        let notesURL = attachDir.appendingPathComponent("notes.txt")
        try "hello".write(to: notesURL, atomically: true, encoding: .utf8)
        let sidecarURL = BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: notesURL)
        try "{}".write(to: sidecarURL, atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        store.reload()
        #expect(store.attachments.count == 1)

        try store.remove(filename: "notes.txt")
        #expect(store.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        try FileManager.default.removeItem(at: tmp)
    }
}
