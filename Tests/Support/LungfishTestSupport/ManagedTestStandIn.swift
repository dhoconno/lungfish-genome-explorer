// ManagedTestStandIn.swift - A stand-in managed tool under a temporary home
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A temporary home that holds stand-in scripts in the managed conda layout,
/// `<home>/.lungfish/conda/envs/<environment>/bin/<tool>`, which is where
/// `NativeToolRunner(toolsDirectory: nil, homeDirectory:)` looks for a managed tool (Phase 2.13 lane 13.17).
/// A test of code that runs zstd or xz installs a script that follows the tool's command line, so the test
/// holds on every Mac and never reaches a tool outside the home.
public struct ManagedTestStandIn {
    /// The temporary home. Pass it as `homeDirectory:` to the runner.
    public let home: URL

    public init(prefix: String) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Writes `script` as an executable `<home>/.lungfish/conda/envs/<environment>/bin/<tool>`, where the
    /// environment is named after the tool unless the caller gives another, and returns its URL.
    @discardableResult
    public func install(_ tool: String, environment: String? = nil, script: String) throws -> URL {
        let bin = home.appendingPathComponent(".lungfish/conda/envs/\(environment ?? tool)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent(tool)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Removes the home and everything in it.
    public func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    /// The path `install(_:environment:script:)` gives a tool.
    public func executableURL(_ tool: String, environment: String? = nil) -> URL {
        home.appendingPathComponent(".lungfish/conda/envs/\(environment ?? tool)/bin/\(tool)")
    }

    /// The first line a stand-in compressor writes before the file it was given.
    public static let compressedMarker = "STAND-IN-COMPRESSED"

    /// A stand-in for zstd's command line. `-c <file>` writes the marker line and then the file to standard
    /// output and fails when the file is missing, and `-dc <file>` writes the file without its first line.
    public static let zstdScript = """
    #!/bin/sh
    case "$1" in
      -c) /usr/bin/printf 'STAND-IN-COMPRESSED\\n' && /bin/cat "$2" ;;
      -dc) /usr/bin/tail -n +2 "$2" ;;
      *) echo "unsupported arguments: $*" >&2; exit 2 ;;
    esac
    """

    /// A stand-in for the decompress half of xz's or zstd's command line, `-dc <file>`, with the same format as
    /// ``zstdScript``.
    public static let decompressScript = """
    #!/bin/sh
    case "$1" in
      -dc) /usr/bin/tail -n +2 "$2" ;;
      *) echo "unsupported arguments: $*" >&2; exit 2 ;;
    esac
    """

    /// A stand-in that never finishes, for a test of a cancel. `exec` makes the shell the sleeping process, so
    /// ending it ends the whole child.
    public static let sleepingScript = """
    #!/bin/sh
    exec /bin/sleep 120
    """
}
