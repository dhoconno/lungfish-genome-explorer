// DemoArchiveStandIn.swift - A loopback server for one demo project archive, and the manifest that names it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

/// Serves one small demo project archive from the loopback stand-in and writes the manifest that
/// names it (Phase 2.10 lane A45 M4, panel decisions C9 and G5). The window's in-process install and
/// `lungfish-cli demo fetch --manifest <file>` read the same bytes, and no test reaches GitHub.
///
/// The project is `demo-fixture`, whose archive holds `Demo Fixture.lungfish` with a one-line
/// `metadata.json` and, with `payloadBytes`, a file of random bytes so that a transfer reports its
/// progress more than once.
struct DemoArchiveStandIn: Sendable {
    static let projectID = "demo-fixture"
    static let projectFolderName = "Demo Fixture.lungfish"
    static let archivePath = "/demo-fixture.zip"

    let server: LoopbackHTTPStandIn
    /// The project as an in-process install reads it, its archive on the loopback server.
    let project: DemoProject
    /// The manifest file, for `--manifest`. It names the archive on an https host that does not exist.
    let manifestURL: URL

    /// - Parameters:
    ///   - root: A scratch folder the stand-in writes its source folder, archive and manifest in.
    ///   - payloadBytes: Random bytes the archive holds besides the project's metadata.
    ///   - declaredSHA256: The checksum the manifest states, the archive's own when nil.
    ///   - hold: When given, the server holds its answer to the archive until the test releases it.
    static func start(
        in root: URL, payloadBytes: Int = 0, declaredSHA256: String? = nil, hold: StandInHold? = nil
    ) throws -> DemoArchiveStandIn {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("source", isDirectory: true)
        let projectDirectory = source.appendingPathComponent(projectFolderName, isDirectory: true)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectDirectory.appendingPathComponent("metadata.json"))
        if payloadBytes > 0 {
            var bytes = [UInt8](repeating: 0, count: payloadBytes)
            arc4random_buf(&bytes, payloadBytes)
            try Data(bytes).write(to: projectDirectory.appendingPathComponent("payload.bin"))
        }
        let archive = root.appendingPathComponent("demo-fixture.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-q", "-r", "-y", archive.path, projectFolderName]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "zip exited \(zip.terminationStatus)"])
        }
        let body = try Data(contentsOf: archive)
        let server = try LoopbackHTTPStandIn.start { request in
            guard request.path == archivePath else { return .notFound }
            hold?.waitForRelease()
            return LoopbackHTTPResponse(contentType: "application/zip", body: body)
        }
        let sha256 = try declaredSHA256 ?? FileDigest.sha256(of: archive)
        func project(at url: URL) -> DemoProject {
            DemoProject(
                id: projectID, title: "Demo Fixture", summary: "A fixture.", chapters: [], projectFolderName: projectFolderName,
                archive: .init(url: url, sha256: sha256, bytes: Int64(body.count)),
                version: "2026.9.44", minimumAppVersion: nil)
        }
        // A manifest names an https archive, so the file names a host that does not exist, and the CLI's stand-in
        // origin (`environment`) serves its path from the loopback server.
        let manifestURL = root.appendingPathComponent("demo-projects.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let named = project(at: URL(string: "https://demo-stand-in.invalid" + archivePath)!)
        try encoder.encode(DemoProjectManifest(projects: [named])).write(to: manifestURL)
        return DemoArchiveStandIn(server: server, project: project(at: server.url(archivePath)), manifestURL: manifestURL)
    }

    /// The environment that serves the manifest's archive from the loopback server to the CLI.
    var environment: [String: String] { ["LUNGFISH_DEMO_STAND_IN_ORIGIN": server.baseURL.absoluteString] }

    func stop() { server.stop() }
}
