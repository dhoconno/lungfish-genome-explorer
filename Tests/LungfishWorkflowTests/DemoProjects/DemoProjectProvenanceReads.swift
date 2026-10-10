// DemoProjectProvenanceReads.swift - Read a demo project's provenance every way LGE reads it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The reads mirror what the app and the CLI do with a project they open.
//
// - Every provenance JSON file goes through the tolerant reader
//   (`ProvenanceEnvelopeReader.load`) and the strict one (`loadCanonical`).
// - Every bundle folder and every payload file goes through the finder
//   (`ProvenanceRecorder.findProvenanceEnvelope`) that the Inspector and
//   `provenance export` use.
// - Every record goes through `ProvenanceLineageResolver`, and is exported as
//   JSON and as a shell script with `ProvenanceExporter` into a folder outside
//   the project.
//
// Nothing here writes into the project. The suites prove that by comparing a
// snapshot of the whole project before and after.

import Foundation
import LungfishCore
@testable import LungfishWorkflow

enum DemoProvenanceReads {
    /// How much of a large project the slow reads cover. The decode and strict
    /// checks always cover every sidecar.
    struct Scope {
        /// Sidecars (and bundle folders) that also get a lineage walk and two
        /// exports. nil means all of them.
        var deepSidecarLimit: Int?
        /// Payload files the finder is asked about. nil means all of them.
        var payloadSelectionLimit: Int?

        static let everything = Scope(deepSidecarLimit: nil, payloadSelectionLimit: nil)
    }

    struct Outcome {
        var sidecars: [DemoProvenanceExpectedFile.Sidecar] = []
        var finder: [DemoProvenanceExpectedFile.FinderPin] = []
        var lineage: [DemoProvenanceExpectedFile.LineagePin] = []
        var deepSidecarCount = 0
        var exportCount = 0
        /// Anything a reader refused, threw on or returned empty-handed.
        var problems: [String] = []
    }

    struct Selection {
        let url: URL
        let relative: String
        let isBundle: Bool
    }

    // MARK: - Discovery

    /// Every provenance JSON file of the project, by relative path.
    static func sidecarURLs(in project: URL) throws -> [URL] {
        try FileManager.default.subpathsOfDirectory(atPath: project.path)
            .filter { relative in
                (relative as NSString).lastPathComponent.hasSuffix("provenance.json")
                    && isRegularFile(project.appendingPathComponent(relative))
            }
            .sorted(by: pathOrder)
            .map { project.appendingPathComponent($0) }
    }

    /// The items the finder is asked about: every bundle folder and every
    /// visible payload file that is not itself a sidecar.
    static func selections(in project: URL) throws -> [Selection] {
        let fileManager = FileManager.default
        var result: [Selection] = []
        for relative in try fileManager.subpathsOfDirectory(atPath: project.path).sorted(by: pathOrder) {
            let url = project.appendingPathComponent(relative)
            let name = url.lastPathComponent
            let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if ProvenanceWriter.isBundleDirectory(url) {
                    result.append(Selection(url: url, relative: relative, isBundle: true))
                }
            } else if type == .typeRegular, !name.hasPrefix("."), !name.hasSuffix("provenance.json") {
                result.append(Selection(url: url, relative: relative, isBundle: false))
            }
        }
        return result
    }

    /// The demo builder's scratch folder, when this Mac still has one. The
    /// released sidecars record their inputs under it as `<workspace>` paths,
    /// and the reader turns such a path into a real one when the file exists.
    /// On a Mac that built the demos a moment ago, a read could then see more
    /// than the released project holds.
    static func demoBuildScratchFolder() -> URL? {
        PortablePath.defaultTemporaryRoots
            .map { $0.appendingPathComponent("lge-demo-build", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - The reads

    static func run(projectURL: URL, exportRoot: URL, scope: Scope = .everything) throws -> Outcome {
        var outcome = Outcome()
        let mask = DemoProvenancePathMask(projectURL: projectURL)

        let sidecars = try sidecarURLs(in: projectURL)
        let deep = sampledIndices(count: sidecars.count, limit: scope.deepSidecarLimit)
        outcome.deepSidecarCount = deep.count
        for (index, url) in sidecars.enumerated() {
            guard let relative = relativePath(of: url, in: projectURL) else {
                outcome.problems.append("sidecar \(url.lastPathComponent) is outside the project")
                continue
            }
            let envelope: ProvenanceEnvelope
            do {
                guard let loaded = try ProvenanceEnvelopeReader.load(fromSidecar: url) else {
                    outcome.problems.append("the tolerant reader returned nothing for \(relative)")
                    continue
                }
                envelope = loaded
            } catch {
                outcome.problems.append("the tolerant reader threw for \(relative) with \(error)")
                continue
            }
            let strictAccepts = (try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: url)) != nil
            let raw = try Data(contentsOf: url)
            var explicitOptions = ""
            do {
                explicitOptions = try explicitOptionsText(envelope.options.explicit, mask: mask)
            } catch {
                outcome.problems.append("encoding the explicit options of \(relative) threw \(error)")
            }
            outcome.sidecars.append(project(
                relative: relative,
                envelope: envelope,
                strictAccepts: strictAccepts,
                route: decodeRoute(of: raw, sidecar: url),
                raw: raw,
                explicitOptions: explicitOptions,
                mask: mask
            ))
            guard deep.contains(index) else { continue }

            let runs = ProvenanceLineageResolver().resolve(envelope: envelope, sidecarURL: url, sourceRootURL: nil)
            let pin = lineagePin(for: relative, runs: runs, project: projectURL, mask: mask, outcome: &outcome)
            outcome.lineage.append(pin)
            if runs.last?.envelope.id != envelope.id {
                outcome.problems.append("the lineage of \(relative) does not end with its own record")
            }
            for format in [ProvenanceExportFormat.json, .shell] {
                export(
                    envelope,
                    format: format,
                    to: exportRoot.appendingPathComponent("sidecar-\(index)-\(format.cliToken)", isDirectory: true),
                    sourceSidecar: url,
                    sourceRoot: url,
                    label: relative,
                    outcome: &outcome
                )
            }
        }

        try askTheFinder(projectURL: projectURL, exportRoot: exportRoot, scope: scope, outcome: &outcome)
        return outcome
    }

    private static func askTheFinder(
        projectURL: URL,
        exportRoot: URL,
        scope: Scope,
        outcome: inout Outcome
    ) throws {
        let all = try selections(in: projectURL)
        let bundles = all.filter(\.isBundle)
        let payloads = all.filter { !$0.isBundle }
        let payloadKeep = sampledIndices(count: payloads.count, limit: scope.payloadSelectionLimit)
        let bundleExport = sampledIndices(count: bundles.count, limit: scope.deepSidecarLimit)
        let exportedBundles = Set(bundles.enumerated().filter { bundleExport.contains($0.offset) }.map(\.element.relative))
        let chosen = (bundles + payloads.enumerated().filter { payloadKeep.contains($0.offset) }.map(\.element))
            .sorted { pathOrder($0.relative, $1.relative) }

        for (position, selection) in chosen.enumerated() {
            let found = ProvenanceRecorder.findProvenanceEnvelope(for: selection.url)
            let foundRelative = found.flatMap { relativePath(of: $0.sidecarURL, in: projectURL) }
            if found != nil, foundRelative == nil {
                outcome.problems.append("the finder returned a sidecar outside the project for \(selection.relative)")
            }
            outcome.finder.append(DemoProvenanceExpectedFile.FinderPin(
                selection: selection.relative,
                isBundle: selection.isBundle,
                sidecar: foundRelative
            ))
            // A payload file resolves to a sidecar that the loop over sidecars
            // walks and exports on its own. Only a bundle folder, the usual
            // Inspector selection, is walked again from the selection.
            guard let found, selection.isBundle else { continue }

            // The Inspector walks the lineage of what the finder returned,
            // with the selection as the root.
            let runs = ProvenanceLineageResolver().resolve(
                envelope: found.envelope,
                sidecarURL: found.sidecarURL,
                sourceRootURL: selection.url
            )
            if runs.last?.envelope.id != found.envelope.id {
                outcome.problems.append("the lineage of \(selection.relative) does not end with its own record")
            }
            // `provenance export <bundle>` exports what the finder returned.
            guard exportedBundles.contains(selection.relative) else { continue }
            for format in [ProvenanceExportFormat.json, .shell] {
                export(
                    found.envelope,
                    format: format,
                    to: exportRoot.appendingPathComponent("bundle-\(position)-\(format.cliToken)", isDirectory: true),
                    sourceSidecar: found.sidecarURL,
                    sourceRoot: selection.url,
                    label: selection.relative,
                    outcome: &outcome
                )
            }
        }
    }

    private static func export(
        _ envelope: ProvenanceEnvelope,
        format: ProvenanceExportFormat,
        to destination: URL,
        sourceSidecar: URL,
        sourceRoot: URL,
        label: String,
        outcome: inout Outcome
    ) {
        do {
            // No signing provider, so an exported report never depends on a
            // signing key in the environment of the Mac that runs the test.
            let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
                envelope,
                format: format,
                to: destination,
                sourceSidecarURL: sourceSidecar,
                sourceRootURL: sourceRoot
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: bundle.primaryArtifactURL.path)
            if ((attributes[.size] as? NSNumber)?.intValue ?? 0) == 0 {
                outcome.problems.append("exporting \(label) as \(format.cliToken) wrote an empty \(bundle.primaryArtifactURL.lastPathComponent)")
            }
            outcome.exportCount += 1
        } catch {
            outcome.problems.append("exporting \(label) as \(format.cliToken) threw \(error)")
        }
    }

    // MARK: - Projection

    private static func project(
        relative: String,
        envelope: ProvenanceEnvelope,
        strictAccepts: Bool,
        route: String,
        raw: Data,
        explicitOptions: String,
        mask: DemoProvenancePathMask
    ) -> DemoProvenanceExpectedFile.Sidecar {
        func descriptor(_ file: ProvenanceFileDescriptor) -> DemoProvenanceExpectedFile.Descriptor {
            DemoProvenanceExpectedFile.Descriptor(
                path: mask.apply(file.path),
                role: file.role.rawValue,
                sha256: file.checksumSHA256,
                size: file.fileSize
            )
        }
        let rawObject = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        return DemoProvenanceExpectedFile.Sidecar(
            sidecar: relative,
            decodedBy: route,
            strictAccepts: strictAccepts,
            workflowName: envelope.workflowName,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            argv: envelope.argv.map { mask.apply($0) },
            durableReplayArgv: envelope.durableReplayArgv.map { $0.map { mask.apply($0) } },
            reproducibleCommand: mask.apply(envelope.reproducibleCommand),
            exitStatus: envelope.exitStatus,
            rawStatus: rawObject?["status"] as? String,
            // The status the decoded record reports. The stored run answers when there is one,
            // otherwise the exit status does, so it must not move when a writer drops the run.
            decodedStatus: envelope.legacyWorkflowRun().status.rawValue,
            embeddedRun: envelope.legacyRun.map {
                DemoProvenanceExpectedFile.EmbeddedRun(status: $0.status.rawValue, stepCount: $0.steps.count)
            },
            explicitOptions: explicitOptions,
            files: envelope.files.map(descriptor),
            outputs: envelope.outputs.map(descriptor),
            steps: envelope.steps.map { step in
                DemoProvenanceExpectedFile.Step(
                    toolName: step.toolName,
                    toolVersion: step.toolVersion,
                    argv: step.argv.map { mask.apply($0) },
                    durableReplayArgv: step.durableReplayArgv.map { $0.map { mask.apply($0) } },
                    exitStatus: step.exitStatus,
                    inputs: step.inputs.map(descriptor),
                    outputs: step.outputs.map(descriptor)
                )
            }
        )
    }

    /// `options.explicit` encoded with `ProvenanceJSON.encoder` and sorted keys,
    /// then masked. The encoder escapes slashes unless told not to, and an
    /// escaped path would slip past the mask, so slashes stay as they are.
    static func explicitOptionsText(_ explicit: [String: ParameterValue], mask: DemoProvenancePathMask) throws -> String {
        let encoder = ProvenanceJSON.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return mask.apply(String(decoding: try encoder.encode(explicit), as: UTF8.self))
    }

    /// The reader does not say which of its steps accepted the bytes, so this
    /// repeats the first two steps of `ProvenanceEnvelopeReader.decode` on the
    /// same resolved bytes. The envelope step is the one `loadCanonical` uses.
    static func decodeRoute(of raw: Data, sidecar: URL) -> String {
        let resolved = PortablePath.resolveJSON(raw, forFileAt: sidecar, encoder: ProvenanceJSON.encoder)
        if (try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: resolved)) != nil {
            return "envelope"
        }
        if (try? ProvenanceJSON.decoder.decode(WorkflowRun.self, from: resolved)) != nil {
            return "workflowRun"
        }
        return "primitiveAdapter"
    }

    private static func lineagePin(
        for relative: String,
        runs: [ProvenanceLineageResolver.ResolvedRun],
        project: URL,
        mask: DemoProvenancePathMask,
        outcome: inout Outcome
    ) -> DemoProvenanceExpectedFile.LineagePin {
        let chain = runs.map { run -> DemoProvenanceExpectedFile.LineageLink in
            var link: String?
            if let sidecarURL = run.sidecarURL {
                link = relativePath(of: sidecarURL, in: project)
                if link == nil {
                    outcome.problems.append("the lineage of \(relative) names a sidecar outside the project, \(mask.apply(sidecarURL.path))")
                }
            }
            return DemoProvenanceExpectedFile.LineageLink(sidecar: link, workflowName: run.envelope.workflowName)
        }
        return DemoProvenanceExpectedFile.LineagePin(sidecar: relative, chain: chain)
    }

    // MARK: - Small helpers

    /// The path of `url` below `project`, comparing the spelling it was given
    /// first and the physical path (`/var` against `/private/var`) second.
    static func relativePath(of url: URL, in project: URL) -> String? {
        let itemComponents = url.standardizedFileURL.pathComponents
        let baseComponents = project.standardizedFileURL.pathComponents
        if itemComponents.count > baseComponents.count,
           Array(itemComponents.prefix(baseComponents.count)) == baseComponents {
            return itemComponents.dropFirst(baseComponents.count).joined(separator: "/")
        }
        guard let physical = CanonicalFilePath.relativePath(of: url, within: project), !physical.isEmpty else {
            return nil
        }
        return physical
    }

    static func pathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Evenly spaced indices, so a bounded run still looks at every part of a large project.
    static func sampledIndices(count: Int, limit: Int?) -> Set<Int> {
        guard let limit, limit < count else { return Set(0 ..< count) }
        guard limit > 0 else { return [] }
        return Set((0 ..< limit).map { $0 * count / limit })
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }
}
