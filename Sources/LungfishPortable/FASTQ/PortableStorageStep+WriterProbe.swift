// PortableStorageStep+WriterProbe.swift - Which writer compresses the gzip output of a BBTools storage step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The writer of a BBTools storage step's gzip bytes (BIO ruling N3). BBTools 40.02 writes BGZF through the first
/// `bgzip` on its `PATH` that answers `bgzip -h`, else through its own BGZF writer, whatever `pigz=t` says.
package enum PortableBBToolsWriter: Sendable, Equatable {
    /// The first `bgzip` on the step's `PATH`, which answered `bgzip -h`, with the argv BBTools gives it.
    case bgzip(executable: URL, arguments: [String])
    /// BBTools' own BGZF writer, used when no `bgzip` on the step's `PATH` answers.
    case nativeBGZF

    /// The writer as a record names it.
    package var name: String {
        switch self {
        case .bgzip: return "bgzip"
        case .nativeBGZF: return "BBTools native BGZF"
        }
    }
}

/// What the writer probe found: the writer of a BBTools storage step's gzip output and the level that takes effect.
package struct PortableBBToolsWriterProbe: Sendable, Equatable {
    package var writer: PortableBBToolsWriter
    package var effectiveCompressionLevel: Int
    /// The version the answering `bgzip` states on its `Version:` line of `bgzip -h`, nil when it states none or
    /// none answered. The Mac records it as read on the Mac (C4-10, XC-4 B).
    package var version: String?

    package init(writer: PortableBBToolsWriter, effectiveCompressionLevel: Int, version: String? = nil) {
        self.writer = writer
        self.effectiveCompressionLevel = effectiveCompressionLevel
        self.version = version
    }
}

extension PortableStorageStep {

    /// The level a BBTools argv compresses at, its `zl=` value, nil when it has none.
    package static func compressionLevel(of arguments: [String]) -> Int? {
        arguments.lazy.compactMap { $0.hasPrefix("zl=") ? Int($0.dropFirst("zl=".count)) : nil }.last
    }

    /// The version on the `Version: <v>` line of `bgzip -h`, which htslib's `bgzip` prints first.
    package static func bgzipVersion(fromHelp text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Version:") else { continue }
            let version = trimmed.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
            return version.isEmpty ? nil : version
        }
        return nil
    }

    /// Runs the probe BBTools runs before it writes gzip, `bgzip -h` with the step's own `PATH`, through the launcher
    /// that runs the step, and names the writer of the stored bytes and the level that takes effect, the `zl=` of
    /// the BBTools argv (4 for the storage `clumpify.sh`, the user's level for `reformat.sh`). `environment` is the
    /// one the BBTools launch gets, built once for the step, so the probe tests the very `PATH` BBTools reads (ARCH
    /// N3 condition 1). The levels an import offers, 1, 4 and 9, are all below the `zl=10` at which BBTools stops
    /// writing BGZF. The executor starts the probe from K4. The Mac import starts it from C4-10 right before each
    /// BBTools launch that writes the stored gzip, and records its result on that launch's step, so no Mac import
    /// starts a process whose result no record holds (ARCH N3 condition 2).
    package func probeBBToolsWriter(
        environment: [String: String],
        compressionLevel: Int,
        threads: Int
    ) async throws -> PortableBBToolsWriterProbe {
        let native = PortableBBToolsWriterProbe(writer: .nativeBGZF, effectiveCompressionLevel: compressionLevel)
        guard let bgzip = Self.firstExecutable(named: "bgzip", onPath: environment["PATH"] ?? "") else {
            return native
        }
        let launch = PortableToolLaunch(
            tool: .bgzip, arguments: ["-h"], environment: environment, timeout: 60, executable: bgzip
        )
        let outcome: PortableToolOutcome
        do {
            outcome = try await launcher.run(launch)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A bgzip that cannot be started does not answer, so BBTools writes with its own writer.
            return native
        }
        guard outcome.isSuccess else { return native }
        return PortableBBToolsWriterProbe(
            writer: .bgzip(
                executable: bgzip,
                arguments: ["-c", "-f", "-l", String(compressionLevel), "-@", String(max(1, threads))]
            ),
            effectiveCompressionLevel: compressionLevel,
            version: Self.bgzipVersion(fromHelp: outcome.stdout) ?? Self.bgzipVersion(fromHelp: outcome.stderr)
        )
    }

    /// The first regular file named `name` in the folders `path` lists that is executable, the one a launch by name
    /// starts.
    package static func firstExecutable(named name: String, onPath path: String) -> URL? {
        let fm = FileManager.default
        for folder in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(folder), isDirectory: true).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
