// MappingToolVersionProbe.swift - The mapper version a mapping run records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The version a mapping run records for its mapper.
///
/// minimap2, BWA-MEM2 and Bowtie2 run through micromamba in their own
/// environment and are probed there with `detectToolVersion`. The probe table
/// marks BWA-MEM2 `.condaMetaOnly`, because its 2.3 build rejects `--version`
/// and `-v` and prints a stale 2.2.1 from `version`, so conda-meta supplies it.
/// BBMap runs through `NativeToolRunner` in the BBTools environment, so the
/// same runner probes it. It runs `reformat.sh --version`, the lightest
/// BBTools wrapper, because `bbmap.sh` and `mapPacBio.sh` start a JVM sized to
/// free memory. Every BBTools wrapper first echoes its `java` command line,
/// which holds the install path (`opt/bbmap-40.02-0`, or a volume named
/// `LGE 2.0`) and for `mapPacBio.sh` the option `minratio=0.40`, so only the
/// whole line `BBTools version X` or `BBMap version X` is read as the version.
enum MappingToolVersionProbe {
    static func version(
        of tool: MappingTool,
        executable: String,
        condaManager: CondaManager,
        nativeToolRunner: NativeToolRunner
    ) async throws -> String {
        switch tool {
        case .bbmap:
            return try await bbToolsVersion(runner: nativeToolRunner)
        case .minimap2, .bwaMem2, .bowtie2:
            return try await detectToolVersion(
                toolName: executable,
                environment: tool.environmentName,
                condaManager: condaManager,
                condaPackage: condaPackage(for: tool)
            )
        }
    }

    /// The conda package whose installed version is the mapper's version, nil for a mapper that
    /// reports its own. The lock id, the environment and the package share one name for the
    /// mappers, and the probe table's dialect says whether the tool's own output is trusted.
    static func condaPackage(for tool: MappingTool) -> String? {
        let id = ManagedToolID(rawValue: tool.environmentName)
        return ManagedToolVersionProbe.probe(for: id)?.dialect == .condaMetaOnly ? id.rawValue : nil
    }

    /// The BBTools version the runner's `reformat.sh` prints, or `unknown`.
    static func bbToolsVersion(runner: NativeToolRunner) async throws -> String {
        let probe = NativeTool.reformat
        let result = try? await runner.run(probe, arguments: probe.versionArguments, timeout: 30)
        if Task.isCancelled { throw CancellationError() }
        guard let result, let version = parseBBToolsVersion(stdout: result.stdout, stderr: result.stderr) else {
            return "unknown"
        }
        return version
    }

    /// The version on a line that reads exactly `BBTools version X` or
    /// `BBMap version X`, in stderr first, where BBTools prints it.
    static func parseBBToolsVersion(stdout: String, stderr: String) -> String? {
        let versionLine = /BB(?:Tools|Map) version (\d+\.\d+(?:\.\d+)?)/
        for output in [stderr, stdout] {
            for line in output.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let match = trimmed.wholeMatch(of: versionLine) {
                    return String(match.1)
                }
            }
        }
        return nil
    }
}
