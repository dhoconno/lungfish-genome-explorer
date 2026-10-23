// ImageManifestCommandTests.swift - lungfish-executor image-manifest through the binary (CHTC lane K4, M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The image build and the Mac replay write a tool manifest with `lungfish-executor image-manifest`, which runs
/// `ImageToolManifest.build(condaPrefixes:)` (ARCH-r3 ruling 3). These tests run the binary, as a CHTC job does.
final class ImageManifestCommandTests: XCTestCase {
    private var folder = ""

    override func setUpWithError() throws {
        folder = try ExecutorTestSupport.scratchFolder()
    }

    override func tearDownWithError() throws {
        if !folder.isEmpty { try? FileManager.default.removeItem(atPath: folder) }
    }

    /// A conda environment with one package that installs an executable `bin/seqkit` and a plain file, and a second
    /// package whose `bin/` file is not executable, so the manifest holds seqkit alone.
    private func makePrefix() throws -> String {
        let prefix = "\(folder)/env"
        let manager = FileManager.default
        try manager.createDirectory(atPath: "\(prefix)/conda-meta", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: "\(prefix)/bin", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: "\(prefix)/share", withIntermediateDirectories: true)
        try Data("{\"name\":\"seqkit\",\"version\":\"2.13.0\",\"build\":\"h9ee0642_0\",\"files\":[\"bin/seqkit\",\"share/seqkit.txt\"]}".utf8)
            .write(to: URL(fileURLWithPath: "\(prefix)/conda-meta/seqkit-2.13.0-h9ee0642_0.json"))
        try Data("{\"name\":\"notes\",\"version\":\"1.0\",\"build\":\"0\",\"files\":[\"bin/notes.txt\"]}".utf8)
            .write(to: URL(fileURLWithPath: "\(prefix)/conda-meta/notes-1.0-0.json"))
        try Data("#!/bin/sh\necho seqkit\n".utf8).write(to: URL(fileURLWithPath: "\(prefix)/bin/seqkit"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(prefix)/bin/seqkit")
        try Data("notes\n".utf8).write(to: URL(fileURLWithPath: "\(prefix)/bin/notes.txt"))
        try Data("text\n".utf8).write(to: URL(fileURLWithPath: "\(prefix)/share/seqkit.txt"))
        return prefix
    }

    /// Runs the binary with `arguments`, returning the exit code, stdout and stderr.
    private func runExecutor(_ arguments: [String], name: String) throws -> (code: Int32, out: String, err: String) {
        let binary = try ExecutorTestSupport.executorBinary()
        let pid = try ExecutorTestSupport.spawn(binary, arguments, folder: folder, name: name)
        guard let exit = ExecutorTestSupport.waitForExit(pid, timeout: 60) else {
            kill(pid, SIGKILL)
            throw ExecutorTestSupport.Failure(description: "lungfish-executor image-manifest did not exit within 60 s")
        }
        guard case .exited(let code) = exit.termination else {
            throw ExecutorTestSupport.Failure(description: "lungfish-executor image-manifest ended by \(exit.termination)")
        }
        return (code, ExecutorTestSupport.text("\(folder)/\(name).out"), ExecutorTestSupport.text("\(folder)/\(name).err"))
    }

    func testImageManifestModeWritesTheBuildersManifestAndRefusesAnExistingOutput() throws {
        let prefix = try makePrefix()
        let output = "\(folder)/image-manifest.json"
        let first = try runExecutor(["image-manifest", "--conda-prefix", prefix + "/", "--output", output], name: "first")
        guard let platform = ImageToolPlatform.current else {
            // A Linux aarch64 test host: the builder knows no conda platform for it, so the mode refuses and writes nothing.
            XCTAssertEqual(first.code, ExecutorExitCode.refused)
            XCTAssertTrue(first.err.contains("platform: This machine is neither linux-64 nor osx-arm64."), first.err)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output))
            return
        }
        XCTAssertEqual(first.code, ExecutorExitCode.succeeded, first.err)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: output))
        let expected = try ImageToolManifest.build(condaPrefixes: [URL(fileURLWithPath: prefix)], platform: platform)
        XCTAssertEqual(bytes, try expected.encoded(), "the mode writes the builder's bytes")
        let manifest = try ImageToolManifest.decode(bytes)
        XCTAssertEqual(manifest.tools, [ImageTool(id: "seqkit", version: "2.13.0", build: "h9ee0642_0",
                                                  path: "\(prefix)/bin/seqkit", condaPackage: "seqkit")])
        XCTAssertEqual(first.out, "sha256 \(PortableDigest.sha256Hex(of: bytes)) size \(bytes.count) tools 1\n")

        let second = try runExecutor(["image-manifest", "--conda-prefix", prefix, "--output", output], name: "second")
        XCTAssertEqual(second.code, ExecutorExitCode.refused)
        XCTAssertTrue(second.err.contains("cannot create \(output)"), second.err)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), bytes, "an existing manifest is never replaced")
    }

    func testImageManifestModeRefusesABadPrefixAndAnIncompleteCommandLine() throws {
        let output = "\(folder)/image-manifest.json"
        try FileManager.default.createDirectory(atPath: "\(folder)/empty", withIntermediateDirectories: true)
        let refused = try runExecutor(["image-manifest", "--conda-prefix", "\(folder)/empty", "--output", output], name: "empty")
        XCTAssertEqual(refused.code, ExecutorExitCode.refused)
        if ImageToolPlatform.current != nil {
            XCTAssertTrue(refused.err.contains("condaPrefix: The environment \(folder)/empty has no conda-meta folder."), refused.err)
        }
        let relative = try runExecutor(["image-manifest", "--conda-prefix", "env", "--output", output], name: "relative")
        XCTAssertEqual(relative.code, ExecutorExitCode.refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))

        for (name, arguments) in [
            ("no-output", ["image-manifest", "--conda-prefix", "\(folder)/empty"]),
            ("no-prefix", ["image-manifest", "--output", output]),
            ("unknown", ["image-manifest", "--conda-prefix", "\(folder)/empty", "--output", output, "--force"]),
        ] {
            let usage = try runExecutor(arguments, name: name)
            XCTAssertEqual(usage.code, ExecutorExitCode.usage, name)
            XCTAssertTrue(usage.err.hasSuffix(ImageManifestCommand.usage), name)
        }
        XCTAssertEqual(ImageManifestCommand.parse(["--conda-prefix", "/a", "--conda-prefix", "/b", "--output", "/m.json"]),
                       .success(ImageManifestCommand.Options(condaPrefixes: ["/a", "/b"], output: "/m.json")))
    }
}
