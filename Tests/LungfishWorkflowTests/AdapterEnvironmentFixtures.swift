// AdapterEnvironmentFixtures.swift - Fake tools that report the environment they received
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S2 (scope row B1). The pins of the adapter child environments
// and the tests of the recorded environment change run these fake tools through
// the real CondaManager.runTool and NativeToolRunner paths. A fake tool is a
// perl script, because perl adds no variable of its own while a shell adds PWD
// and SHLVL, so a dump is exactly the environment the adapter gave ToolProcess.

import Foundation
import Synchronization
import XCTest
@testable import LungfishWorkflow
import LungfishCore

/// The fake tools and the reader of what they report.
enum EnvironmentDump {
    /// Writes the environment it received to the file named by its first
    /// argument, as `NAME=value` and a NUL for each variable sorted by name,
    /// then drains standard input so a pipeline stage can end.
    static let tool = """
    #!/usr/bin/perl
    my $out = shift @ARGV;
    open(my $fh, '>', $out) or die "cannot open $out: $!";
    binmode($fh);
    foreach my $name (sort keys %ENV) { print $fh $name, '=', $ENV{$name}, "\\0"; }
    close($fh);
    local $/;
    my $discard = <STDIN>;
    exit 0;
    """

    /// A micromamba that answers `--version` and, for `run -n ENV NAME FILE`,
    /// writes the environment it received to FILE.
    static let micromamba = """
    #!/usr/bin/perl
    if (@ARGV && $ARGV[0] eq '--version') { print "2.0.5-0\\n"; exit 0; }
    if (@ARGV >= 5 && $ARGV[0] eq 'run') {
        my $out = $ARGV[4];
        open(my $fh, '>', $out) or die "cannot open $out: $!";
        binmode($fh);
        foreach my $name (sort keys %ENV) { print $fh $name, '=', $ENV{$name}, "\\0"; }
        close($fh);
        exit 0;
    }
    print STDERR "unexpected arguments: @ARGV\\n";
    exit 1;
    """

    /// The variables a dump holds.
    static func read(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else {
                XCTFail("A dump entry has no name: \(text)")
                continue
            }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// Fails with every name whose value differs, is missing or is extra.
    ///
    /// Names that start with `DYLD_` are left out of both sides. The system
    /// removes them from the environment of a protected program such as perl,
    /// so a dump never holds the ones the test process itself runs under.
    static func assertEqual(
        _ actual: [String: String],
        _ expected: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func kept(_ environment: [String: String]) -> [String: String] {
            environment.filter { !$0.key.hasPrefix("DYLD_") }
        }
        let actual = kept(actual)
        let expected = kept(expected)
        var differences: [String] = []
        for name in Set(actual.keys).union(expected.keys).sorted() {
            switch (actual[name], expected[name]) {
            case let (got?, want?) where got != want:
                differences.append("\(name): expected \(want), got \(got)")
            case let (got?, nil):
                differences.append("\(name): not expected, got \(got)")
            case let (nil, want?):
                differences.append("\(name): expected \(want), missing")
            default:
                break
            }
        }
        XCTAssertTrue(
            differences.isEmpty,
            "The child environment differs in \(differences.count) names\n" + differences.prefix(20).joined(separator: "\n"),
            file: file,
            line: line
        )
    }
}

/// Sets variables in the environment of the test process and puts them back.
///
/// The adapters read the environment of the process that runs them, so a test
/// fixes the parent environment this way. Tests of one process run one at a
/// time, and a test restores the environment before it ends.
struct ParentEnvironmentOverride {
    private let saved: [(name: String, value: String?)]

    /// Sets each name to its value, or removes it when the value is nil.
    init(_ values: [String: String?]) {
        saved = values.keys.sorted().map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, value) in values {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }

    func restore() {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
}

/// Collects observations the way a provenance buffer does, with one append
/// under a lock and nothing else.
final class AdapterObservationLog: Sendable {
    private let observations = Mutex<[ToolProcessRunObservation]>([])

    var observer: ToolProcessObserver {
        ToolProcessObserver { [self] observation in
            observations.withLock { $0.append(observation) }
        }
    }

    var all: [ToolProcessRunObservation] {
        observations.withLock { $0 }
    }
}

/// A managed tool root, with no whitespace in its path, whose fake tools
/// report the environment they received.
struct AdapterToolRoot {
    let root: URL
    let runner: NativeToolRunner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-adapter-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Debug, because a Preview home also honours the legacy
        // DatabaseStorageLocation preference of the test process's defaults
        // domain, which can point tool resolution away from this root.
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .debug)
    }

    /// The `bin` folder of the conda environment that holds `tool`.
    func binDirectory(of tool: NativeTool) -> URL {
        guard case .managed(let environment, _) = tool.location else { preconditionFailure("\(tool) is not managed") }
        return environmentURL(environment).appendingPathComponent("bin", isDirectory: true)
    }

    func environmentURL(_ environment: String) -> URL {
        CoreToolLocator.environmentURL(named: environment, homeDirectory: root, appIdentity: .debug)
    }

    /// Installs the dumping tool as the managed executable of `tool`.
    func install(_ tool: NativeTool) throws {
        guard case .managed(_, let executableName) = tool.location else { return }
        let directory = binDirectory(of: tool)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(directory.appendingPathComponent(executableName))
    }

    /// Installs the dumping tool outside any managed environment.
    func installStandaloneTool() throws -> URL {
        let url = root.appendingPathComponent("dumper")
        try writeExecutable(url)
        return url
    }

    /// The file a fake tool named `name` writes its dump to.
    func dumpURL(_ name: String) -> URL {
        root.appendingPathComponent("dump-\(name).bin")
    }

    /// A folder that exists, to stand in for the parent's TMPDIR.
    func scratchDirectory() throws -> URL {
        let url = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(_ url: URL) throws {
        try EnvironmentDump.tool.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// A CondaManager rooted in a fresh sandbox whose micromamba reports the
/// environment it received.
struct AdapterCondaRoot {
    let sandbox: URL
    let manager: CondaManager

    init() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-adapter-conda-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let bundled = sandbox.appendingPathComponent("bundled-micromamba")
        try EnvironmentDump.micromamba.write(to: bundled, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundled },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()
        self.sandbox = sandbox
        self.manager = manager
    }

    /// The file the fake micromamba writes the dump named `name` to.
    func dumpURL(_ name: String) -> URL {
        sandbox.appendingPathComponent("dump-\(name).bin")
    }

    /// A folder that exists, to stand in for the parent's TMPDIR.
    func scratchDirectory() throws -> URL {
        let url = sandbox.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
