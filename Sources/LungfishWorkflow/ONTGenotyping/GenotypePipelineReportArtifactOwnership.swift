import CryptoKit
import Darwin
import Foundation
import LungfishIO

/// Current-run inventory only; the enclosing producer owns publication and rollback.
/// Never discovers sibling exports or adopts files introduced after capture.
struct GenotypePipelineReportArtifactOwnership {
    private struct Root {
        var url: URL
        let identity: FileSystemObjectIdentity
        let members: [String: FileSystemObjectIdentity]?
        var removed = false
    }
    private var roots: [Root] = []

    mutating func captureDefinition(_ created: DurableAtomicFileStore.OpenPublishedFile) throws {
        // Registration cannot depend on reopening a pathname that may already
        // be missing or replaced. Identity comes from the writer's open inode.
        roots.append(.init(url: created.url, identity: created.identity, members: nil))
        guard try FileSystemObjectIdentity.noFollow(created.url) == created.identity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(created.url.path)
        }
    }

    mutating func captureExport(_ export: GenotypeExcelExportService.ExportResult) throws {
        let directory = export.artifactDirectoryURL.standardizedFileURL
        // Keep the complete writer-supplied inventory before any current-path
        // validation can throw. Missing members still need failure diagnostics.
        roots.append(.init(url: directory, identity: export.artifactDirectoryIdentity,
            members: export.artifactIdentities))
        guard Set(export.artifactURLs.map(\.lastPathComponent)) == Set(export.artifactIdentities.keys),
              export.artifactURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory }),
              export.artifactIdentities.keys.allSatisfy(Self.isMemberName) else {
            throw GenotypeExcelExportService.ExportError.invalidInput("invalid declared report artifact inventory")
        }
        guard try FileSystemObjectIdentity.noFollow(directory) == export.artifactDirectoryIdentity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(directory.path)
        }
        for (name, identity) in export.artifactIdentities {
            let file = directory.appendingPathComponent(name)
            guard try FileSystemObjectIdentity.noFollow(file) == identity else {
                throw OwnedWorkDirectoryMarkerError.identityMismatch(file.path)
            }
        }
    }

    private static func isMemberName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    /// Failure history must not follow a replacement while attesting survivors.
    /// Hash and size come from the same no-follow, identity-checked file handle.
    func failureInventory() -> (outputs: [[String: Any]], diagnostics: [[String: String]]) {
        var outputs: [[String: Any]] = []
        var diagnostics: [[String: String]] = []
        for root in roots where !root.removed {
            let members = root.members ?? [root.url.lastPathComponent: root.identity]
            for (name, identity) in members.sorted(by: { $0.key < $1.key }) {
                let file = root.members == nil ? root.url : root.url.appendingPathComponent(name)
                do {
                    guard Self.isMemberName(name) else {
                        throw GenotypeExcelExportService.ExportError.invalidInput("unsafe report member name")
                    }
                    outputs.append(try descriptor(file, identity: identity,
                        directoryIdentity: root.members == nil ? nil : root.identity))
                } catch {
                    diagnostics.append(["path": file.standardizedFileURL.path,
                        "error": error.localizedDescription])
                }
            }
        }
        return (outputs, diagnostics)
    }

    private func descriptor(
        _ file: URL, identity: FileSystemObjectIdentity,
        directoryIdentity: FileSystemObjectIdentity?
    ) throws -> [String: Any] {
        let file = file.standardizedFileURL
        let parent = file.deletingLastPathComponent()
        let directory = try NoFollowFileSystem.openDirectoryHierarchy(parent)
        defer { Darwin.close(directory) }
        if let directoryIdentity {
            var info = stat()
            guard Darwin.fstat(directory, &info) == 0,
                  FileSystemObjectIdentity(from: info) == directoryIdentity else {
                throw OwnedWorkDirectoryMarkerError.identityMismatch(parent.path)
            }
        }
        let descriptor = file.lastPathComponent.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(file.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              FileSystemObjectIdentity(from: before) == identity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(file.path)
        }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            size += UInt64(data.count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_size == after.st_size, size == UInt64(after.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              try FileSystemObjectIdentity.noFollow(file) == identity,
              try directoryIdentity == nil || FileSystemObjectIdentity.noFollow(parent) == directoryIdentity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(file.path)
        }
        return ["path": file.path, "role": "output", "fileSize": size,
            "sha256": hasher.finalize().map { String(format: "%02x", $0) }.joined()]
    }

    mutating func rollback(remover: (URL) throws -> Void) -> [AmpliconWorkDirectoryDisposition] {
        roots.indices.map { index in
            let root = roots[index]
            let entry = GenotypingCleanupPlanEntry(path: root.url.path,
                intendedAction: .removeRetiredPublicationDirectory, identity: root.identity)
            var detachedURL: URL?
            let outcome = GenotypingIdentityBoundCleanup.remove(entry) { detached in
                detachedURL = detached
                if let members = root.members {
                    let actual = try FileManager.default.contentsOfDirectory(at: detached, includingPropertiesForKeys: nil)
                    guard Set(actual.map(\.lastPathComponent)) == Set(members.keys),
                          actual.allSatisfy({ (try? FileSystemObjectIdentity.noFollow($0)) == members[$0.lastPathComponent] }) else {
                        throw GenotypeExcelExportService.ExportError.invalidInput("owned report members changed; retaining directory")
                    }
                }
                try remover(detached)
            }
            // The shared cleanup owner normally restores a failed removal. If an
            // unrelated replacement blocks restoration, retain the exact detached
            // location in the failed-run file inventory instead of losing its bytes.
            if (try? FileSystemObjectIdentity.noFollow(root.url)) != root.identity,
               let detachedURL, (try? FileSystemObjectIdentity.noFollow(detachedURL)) == root.identity {
                roots[index].url = detachedURL
            }
            switch outcome {
            case .removed:
                roots[index].removed = true
                return .init(path: root.url.path, disposition: "removed", error: nil)
            case .identityMismatch(let detail):
                return .init(path: root.url.path, disposition: "retained-identity-mismatch", error: detail)
            case .failed(let detail):
                return .init(path: roots[index].url.path, disposition: "retained-cleanup-failed", error: detail)
            case .retained:
                return .init(path: roots[index].url.path, disposition: "retained-cleanup-failed", error: "Report artifact was retained.")
            }
        }
    }
}
