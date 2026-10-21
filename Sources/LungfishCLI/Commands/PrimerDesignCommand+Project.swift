// PrimerDesignCommand+Project.swift - Where a primers design leaf writes its bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// `--output`, `--project` and `--name` of the four `primers design` leaves (Phase 2.13 lane 13.43, row PRIMER-PROJECT).
///
/// A result in a project takes `--project`, so a replay in Terminal makes a new result and leaves the old one alone
/// (`docs/contracts/ADDING-AN-OPERATION.md`, the Copy CLI Command part). `--output` names one exact bundle, which the
/// leaf refuses when it exists. `--project` names the project that gets a new bundle, `<project>/Analyses/<name>
/// .lungfishprimeranalysis`, where a name in use becomes `<name> 2`, `<name> 3` and so on, as the dialog's "keep both"
/// naming does, so a second run of the same command writes another bundle and never touches the first. The leaf makes the
/// project's `Analyses` folder when it is missing, after its arguments and inputs pass.
extension PrimerDesignCommand {
    /// The name of the bundle `--project` writes when `--name` is missing, the dialog's own default.
    static let defaultProjectBundleName = "Primer analysis"

    /// The help of `--output`, the same words on the four leaves.
    static let outputHelp = ArgumentHelp("New .lungfishprimeranalysis destination. It must not exist. Give --output or --project.")
    /// The help of `--project`.
    static let projectHelp = ArgumentHelp(
        "Project to write a new Analyses/<name>.lungfishprimeranalysis bundle in, as the app does. A second run writes another new bundle. Give --output or --project.")
    /// The help of `--name`.
    static let nameHelp = ArgumentHelp(
        "Name of the bundle --project writes, without the extension (default: \(defaultProjectBundleName)). A name in use becomes <name> 2, <name> 3 and so on.")

    /// Checks `--output`, `--project` and `--name` together, before any input is read or folder made. A leaf calls it from
    /// `validate()`.
    static func validateDestinationOptions(output: String?, project: String?, name: String?) throws {
        if output != nil, project != nil {
            throw ValidationError("--output and --project name two places for one result. Give one of them.")
        }
        if output == nil, project == nil {
            throw ValidationError("Give --output to name the new bundle, or --project to write a new bundle in the project.")
        }
        if let project, project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--project must name a project folder.")
        }
        guard let name else { return }
        guard project != nil else {
            throw ValidationError("--name names the bundle that --project writes. Give --project, or put the name in --output.")
        }
        try validateBundleName(name)
    }

    /// The dialog's rules for an analysis name (`PrimerDesignDialogState.validatedDestinationURL`), so a name the app
    /// accepts is a name the command accepts.
    static func validateBundleName(_ raw: String) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              name.utf8.count <= 200 else {
            throw ValidationError("--name must be a name without path separators or control characters (up to 200 bytes).")
        }
    }

    /// The bundle this run writes. An `--output` that exists is refused first (`refuseExistingOutput`, exit 3). With
    /// `--project` the bundle is the first free `<name>.lungfishprimeranalysis` in the project's Analyses folder, and a
    /// project that is missing, an `Analyses` link or an `Analyses` file is refused with exit 3 and the words that name the
    /// fix. Nothing is created here, so a refusal leaves no folder.
    static func resolveDestination(
        output: String?, project: String?, name: String?,
        standardError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) throws -> URL {
        if let project {
            return try projectDestination(project: project, name: name, standardError: standardError)
        }
        guard let output else {
            throw ValidationError("Give --output to name the new bundle, or --project to write a new bundle in the project.")
        }
        try refuseExistingOutput(output, standardError: standardError)
        return URL(fileURLWithPath: output)
    }

    private static func projectDestination(
        project: String, name: String?, standardError: (String) -> Void
    ) throws -> URL {
        let projectURL = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            standardError("Project folder not found: \(projectURL.path). Give --project the folder of the project, or use --output to name the bundle.")
            throw CLIExitCode.inputError.exitCode
        }
        let analyses = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        // attributesOfItem and destinationOfSymbolicLink read a link itself, so a link counts even when it dangles.
        if (try? manager.destinationOfSymbolicLink(atPath: analyses.path)) != nil {
            standardError("The project's Analyses folder is a symbolic link: \(analyses.path). Replace it with a folder, or use --output to name the bundle.")
            throw CLIExitCode.inputError.exitCode
        }
        if manager.fileExists(atPath: analyses.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            standardError("The project's Analyses path is not a folder: \(analyses.path). Move it away, or use --output to name the bundle.")
            throw CLIExitCode.inputError.exitCode
        }
        let base = (name ?? defaultProjectBundleName).trimmingCharacters(in: .whitespacesAndNewlines)
        func bundle(_ stem: String) -> URL {
            analyses.appendingPathComponent(stem + ".lungfishprimeranalysis", isDirectory: true)
        }
        func taken(_ stem: String) -> Bool {
            (try? manager.attributesOfItem(atPath: bundle(stem).path)) != nil
        }
        var stem = base
        var counter = 2
        while taken(stem) {
            stem = "\(base) \(counter)"
            counter += 1
        }
        return bundle(stem)
    }
}
