// DemoProjectTestSupport.swift - Tiny ZIP writer and fakes for demo project tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
@testable import LungfishWorkflow

/// Writes uncompressed ("stored") ZIP archives with exact control over entry
/// names and Unix modes, so tests can build malicious archives that `zip(1)`
/// would refuse to create.
enum TestZipWriter {
    enum Kind {
        case file(Data)
        case directory
        case symlink(target: String)
    }

    struct Entry {
        let name: String
        let kind: Kind

        static func file(_ name: String, _ contents: String) -> Entry {
            Entry(name: name, kind: .file(Data(contents.utf8)))
        }

        static func directory(_ name: String) -> Entry {
            Entry(name: name.hasSuffix("/") ? name : name + "/", kind: .directory)
        }

        static func symlink(_ name: String, to target: String) -> Entry {
            Entry(name: name, kind: .symlink(target: target))
        }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let payload: Data
            let mode: UInt32
            switch entry.kind {
            case .file(let data):
                payload = data
                mode = 0o100644
            case .directory:
                payload = Data()
                mode = 0o040755
            case .symlink(let target):
                payload = Data(target.utf8)
                mode = 0o120777
            }
            let name = Data(entry.name.utf8)
            let crc = crc32(payload)
            let offset = UInt32(archive.count)

            archive.append(le32: 0x0403_4b50)
            archive.append(le16: 20)
            archive.append(le16: 0x0800)
            archive.append(le16: 0)
            archive.append(le16: 0)
            archive.append(le16: 0x5821)
            archive.append(le32: crc)
            archive.append(le32: UInt32(payload.count))
            archive.append(le32: UInt32(payload.count))
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0)
            archive.append(name)
            archive.append(payload)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 0x031E)
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0x5821)
            central.append(le32: crc)
            central.append(le32: UInt32(payload.count))
            central.append(le32: UInt32(payload.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le32: mode << 16)
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(central.count))
        archive.append(le32: centralOffset)
        archive.append(le16: 0)
        try archive.write(to: url)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

/// Serves a local file as the "download", with no network.
final class FixtureArchiveLoader: DemoProjectArchiveLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []
    let fixtureURL: URL?
    let error: Error?

    init(fixtureURL: URL?, error: Error? = nil) {
        self.fixtureURL = fixtureURL
        self.error = error
    }

    var requestedURLs: [URL] {
        lock.withLock { _requestedURLs }
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        lock.withLock { _requestedURLs.append(url) }
        if let error { throw error }
        guard let fixtureURL else { throw DemoProjectError.notFound(url) }
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress(size / 2, size)
        progress(size, size)
    }
}

enum DemoProjectFixtures {
    static let folderName = "Demo Fixture.lungfish"

    static func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    /// A small, valid project archive.
    static func writeProjectArchive(to url: URL, folderName: String = folderName) throws {
        try TestZipWriter.write([
            .directory(folderName),
            .file("\(folderName)/metadata.json", "{\"name\":\"Demo Fixture\"}"),
            .directory("\(folderName)/Reference Sequences"),
            .file("\(folderName)/Reference Sequences/ref.fa", ">chr1\nACGT\n"),
            .symlink("\(folderName)/latest.fa", to: "Reference Sequences/ref.fa"),
        ], to: url)
    }

    static func project(
        id: String = "demo-fixture",
        folderName: String = folderName,
        archiveURL: URL,
        version: String = "2026.9.44",
        minimumAppVersion: String? = "2026.9.1",
        overrideSHA: String? = nil,
        overrideBytes: Int64? = nil
    ) throws -> DemoProject {
        let bytes = (try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try FileDigest.sha256(of: archiveURL)
        return DemoProject(
            id: id,
            title: "Demo Fixture",
            summary: "A fixture.",
            chapters: [.init(title: "Importing", path: "chapters/02-sequences/01-importing-and-viewing/")],
            projectFolderName: folderName,
            archive: .init(
                url: URL(string: "https://example.invalid/\(id).zip")!,
                sha256: overrideSHA ?? sha,
                bytes: overrideBytes ?? bytes
            ),
            version: version,
            minimumAppVersion: minimumAppVersion
        )
    }
}

/// Collects items "moved to the Trash" in a temp folder instead of the real Trash.
final class TestTrash: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var _trashed: [URL] = []

    init(directory: URL) {
        self.directory = directory
    }

    var trashed: [URL] {
        lock.withLock { _trashed }
    }

    var handler: DemoProjectInstaller.TrashHandler {
        { [self] url in
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
            lock.withLock { _trashed.append(url) }
            return destination
        }
    }
}
