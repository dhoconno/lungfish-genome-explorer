import Darwin
import Foundation
import Testing
@testable import LungfishCore

@Suite("Managed storage dedupe")
struct ManagedStorageDedupeTests {
    private struct Fixture {
        let base: URL
        let roots: [URL]

        init(rootNames: [String] = ["preview", "stable"]) throws {
            let baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dedupe-\(UUID().uuidString)", isDirectory: true)
            base = baseURL
            roots = rootNames.map { baseURL.appendingPathComponent($0, isDirectory: true) }
            for root in roots {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("databases/kraken2/viral", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("conda/pkgs", isDirectory: true), withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("conda/envs", isDirectory: true), withIntermediateDirectories: true
                )
            }
        }

        func remove() { try? FileManager.default.removeItem(at: base) }

        @discardableResult
        func write(_ relativePath: String, in root: URL, seed: UInt8, size: Int = 64 * 1024) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.payload(seed: seed, size: size).write(to: url)
            return url
        }

        static func payload(seed: UInt8, size: Int) -> Data {
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                for index in 0..<buffer.count { buffer[index] = UInt8(truncatingIfNeeded: index &+ Int(seed)) }
            }
            return data
        }
    }

    private static func inode(_ url: URL) -> ino_t {
        var metadata = stat()
        _ = lstat(url.path, &metadata)
        return metadata.st_ino
    }

    private func deduplicator(openFiles: Set<String> = []) -> ManagedStorageDeduplicator {
        ManagedStorageDeduplicator(
            openFileDetector: { openFiles.contains($0.path) },
            cloneIdentifier: APFSCloneSupport.cloneIdentifier(of:),
            now: Date.init
        )
    }

    @Test("Dry run finds cross-root duplicates and changes nothing")
    func dryRunFindsDuplicates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.write("databases/kraken2/viral/hash.k2d", in: fixture.roots[0], seed: 1)
        let b = try fixture.write("databases/kraken2/viral/hash.k2d", in: fixture.roots[1], seed: 1)
        try fixture.write("databases/kraken2/viral/opts.k2d", in: fixture.roots[0], seed: 2)
        try fixture.write("databases/kraken2/viral/opts.k2d", in: fixture.roots[1], seed: 3)
        let inodeBefore = Self.inode(b)

        let report = try deduplicator().dryRun(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.mode == .dryRun)
        #expect(report.filesExamined == 4)
        #expect(report.duplicateSets == 1)
        #expect(report.duplicateFiles == 1)
        #expect(report.bytesReclaimable == 64 * 1024)
        #expect(report.bytesReclaimed == 0)
        #expect(report.sets.first?.keptPath == a.path)
        #expect(report.sets.first?.duplicatePaths == [b.path])
        #expect(report.roots.map(\.duplicateFiles) == [0, 1])
        #expect(Self.inode(b) == inodeBefore)
        #expect(try Data(contentsOf: b) == Fixture.payload(seed: 1, size: 64 * 1024))
        #expect(!FileManager.default.fileExists(atPath: fixture.roots[0].appendingPathComponent(ManagedStorageDeduplicator.logFilename).path))
    }

    @Test("Apply replaces the duplicate with a verified clone and preserves metadata")
    func applyReplacesWithClone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let kept = try fixture.write("conda/pkgs/tool-1.0/lib/libtool.dylib", in: fixture.roots[0], seed: 7)
        let duplicate = try fixture.write("conda/pkgs/tool-1.0/lib/libtool.dylib", in: fixture.roots[1], seed: 7)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: duplicate.path)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: duplicate.path)
        let attributeValue = Data("dedupe-test".utf8)
        _ = attributeValue.withUnsafeBytes { bytes in
            setxattr(duplicate.path, "com.lungfish.test", bytes.baseAddress, bytes.count, 0, 0)
        }
        let inodeBefore = Self.inode(duplicate)

        let report = try deduplicator().apply(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.mode == .apply)
        #expect(report.duplicateSets == 1)
        #expect(report.bytesReclaimed == 64 * 1024)
        #expect(report.replacements.map(\.path) == [duplicate.path])
        #expect(report.failures.isEmpty)
        #expect(Self.inode(duplicate) != inodeBefore)
        #expect(try Data(contentsOf: duplicate) == Fixture.payload(seed: 7, size: 64 * 1024))
        let attributes = try FileManager.default.attributesOfItem(atPath: duplicate.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o640)
        #expect(abs(((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince(modified)) < 1)
        var buffer = [UInt8](repeating: 0, count: 32)
        let length = getxattr(duplicate.path, "com.lungfish.test", &buffer, buffer.count, 0, 0)
        #expect(length == attributeValue.count)
        #expect(Data(buffer.prefix(max(0, length))) == attributeValue)
        if APFSCloneSupport.isAPFSVolume(fixture.base),
           let keptClone = APFSCloneSupport.cloneIdentifier(of: kept),
           let duplicateClone = APFSCloneSupport.cloneIdentifier(of: duplicate) {
            #expect(keptClone == duplicateClone)
        }
        #expect(!FileManager.default.fileExists(atPath: kept.deletingLastPathComponent().path + "/" + ManagedStorageDeduplicator.temporaryPrefix))
        for root in fixture.roots {
            let log = root.appendingPathComponent(ManagedStorageDeduplicator.logFilename)
            let contents = try String(contentsOf: log, encoding: .utf8)
            #expect(contents.contains("\"mode\":\"apply\""))
        }
        // Rerunning finds the pair already shared and reclaims nothing more.
        let again = try deduplicator().dryRun(ManagedStorageDedupeOptions(roots: fixture.roots))
        if APFSCloneSupport.isAPFSVolume(fixture.base) {
            #expect(again.duplicateSets == 0)
            #expect(again.bytesAlreadyShared == 64 * 1024)
        }
    }

    @Test("Symbolic links are never followed or replaced")
    func symlinkSafety() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside.bin")
        try Fixture.payload(seed: 4, size: 64 * 1024).write(to: outside)
        try fixture.write("databases/kraken2/viral/taxo.k2d", in: fixture.roots[0], seed: 4)
        let link = fixture.roots[1].appendingPathComponent("databases/kraken2/viral/taxo.k2d")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let directoryLink = fixture.roots[1].appendingPathComponent("databases/elsewhere")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: fixture.roots[0].appendingPathComponent("databases"))
        let outsideInode = Self.inode(outside)

        let report = try deduplicator().apply(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.filesExamined == 1)
        #expect(report.duplicateSets == 0)
        #expect(Self.inode(outside) == outsideInode)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == outside.path)
    }

    @Test("Hard links and existing clones are not double counted")
    func hardlinksAndClonesNotDoubleCounted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cached = try fixture.write("conda/pkgs/zlib-1.3/lib/libz.dylib", in: fixture.roots[0], seed: 9)
        let linked = fixture.roots[0].appendingPathComponent("conda/envs/tool/lib/libz.dylib")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: cached, to: linked)
        let cloned = fixture.roots[1].appendingPathComponent("conda/pkgs/zlib-1.3/lib/libz.dylib")
        try FileManager.default.createDirectory(at: cloned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try APFSCloneSupport.cloneItem(at: cached, to: cloned)

        let report = try deduplicator().dryRun(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.filesExamined == 3)
        if APFSCloneSupport.isAPFSVolume(fixture.base), APFSCloneSupport.cloneIdentifier(of: cached) != nil {
            #expect(report.duplicateSets == 0)
            #expect(report.bytesReclaimable == 0)
            #expect(report.bytesAlreadyShared == 64 * 1024)
        }
    }

    @Test("A hard-linked family is replaced completely so its inode is freed")
    func hardlinkedFamilyReplacedCompletely() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The family with more hard links is kept (fewer replacements), so the
        // preview root gets three links and the stable root's two-link family
        // is the duplicate that must be replaced as a whole.
        let keptCache = try fixture.write("conda/pkgs/zlib-1.3/lib/libz.dylib", in: fixture.roots[0], seed: 5)
        for environment in ["tool-a", "tool-b"] {
            let link = fixture.roots[0].appendingPathComponent("conda/envs/\(environment)/lib/libz.dylib")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: keptCache, to: link)
        }
        let cached = try fixture.write("conda/pkgs/zlib-1.3/lib/libz.dylib", in: fixture.roots[1], seed: 5)
        let linked = fixture.roots[1].appendingPathComponent("conda/envs/tool/lib/libz.dylib")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: cached, to: linked)
        let oldInode = Self.inode(cached)
        let keptInode = Self.inode(keptCache)

        let report = try deduplicator().apply(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.duplicateSets == 1)
        #expect(report.duplicateFiles == 2)
        #expect(report.bytesReclaimed == 64 * 1024)
        #expect(Set(report.replacements.map(\.path)) == [cached.path, linked.path])
        #expect(Self.inode(cached) != oldInode)
        #expect(Self.inode(linked) != oldInode)
        #expect(Self.inode(keptCache) == keptInode)
        #expect(try Data(contentsOf: linked) == Fixture.payload(seed: 5, size: 64 * 1024))
    }

    @Test("Links outside the scanned trees and open files are left alone")
    func externalLinksAndOpenFilesSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("databases/x/a.bin", in: fixture.roots[0], seed: 6)
        let external = try fixture.write("databases/x/a.bin", in: fixture.roots[1], seed: 6)
        let elsewhere = fixture.base.appendingPathComponent("elsewhere.bin")
        try FileManager.default.linkItem(at: external, to: elsewhere)
        try fixture.write("databases/y/b.bin", in: fixture.roots[0], seed: 8)
        let open = try fixture.write("databases/y/b.bin", in: fixture.roots[1], seed: 8)
        let externalInode = Self.inode(external)
        let openInode = Self.inode(open)

        let report = try deduplicator(openFiles: [open.path]).apply(ManagedStorageDedupeOptions(roots: fixture.roots))

        #expect(report.duplicateSets == 0)
        #expect(report.filesWithExternalLinks == 1)
        #expect(report.filesOpenElsewhere == 1)
        #expect(report.bytesReclaimed == 0)
        #expect(Self.inode(external) == externalInode)
        #expect(Self.inode(open) == openInode)
    }

    @Test("Apply refuses while an install transaction is in flight")
    func applyRefusesDuringInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("databases/kraken2/viral/hash.k2d", in: fixture.roots[0], seed: 1)
        try fixture.write("databases/kraken2/viral/hash.k2d", in: fixture.roots[1], seed: 1)
        try FileManager.default.createDirectory(
            at: fixture.roots[1].appendingPathComponent("databases/kraken2/.install-\(UUID().uuidString)", isDirectory: true),
            withIntermediateDirectories: true
        )

        let dry = try deduplicator().dryRun(ManagedStorageDedupeOptions(roots: fixture.roots))
        #expect(dry.blockers.count == 1)
        #expect(dry.duplicateSets == 1)
        #expect(throws: ManagedStorageDedupeError.self) {
            try deduplicator().apply(ManagedStorageDedupeOptions(roots: fixture.roots))
        }
    }

    @Test("A held conda install lock blocks apply")
    func condaLockBlocksApply() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lockURL = fixture.roots[0].appendingPathComponent("conda/.install.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

        let blockers = deduplicator().installBlockers(in: fixture.roots)
        #expect(blockers.count == 1)
        #expect(blockers.first?.contains(".install.lock") == true)
        flock(fd, LOCK_UN)
        #expect(deduplicator().installBlockers(in: fixture.roots).isEmpty)
    }

    @Test("Clone identifiers separate clones from independent copies")
    func cloneIdentifierProbe() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.write("databases/a/original.bin", in: fixture.roots[0], seed: 2)
        let clone = fixture.roots[0].appendingPathComponent("databases/a/clone.bin")
        try APFSCloneSupport.cloneItem(at: original, to: clone)
        let copy = try fixture.write("databases/a/copy.bin", in: fixture.roots[0], seed: 2)
        #expect(try Data(contentsOf: clone) == Data(contentsOf: original))
        guard APFSCloneSupport.isAPFSVolume(fixture.base),
              let originalID = APFSCloneSupport.cloneIdentifier(of: original) else { return }
        #expect(APFSCloneSupport.cloneIdentifier(of: clone) == originalID)
        #expect(APFSCloneSupport.cloneIdentifier(of: copy) != originalID)
        #expect(throws: APFSCloneSupport.CloneError.self) {
            try APFSCloneSupport.cloneItem(at: original, to: clone)
        }
    }
}
