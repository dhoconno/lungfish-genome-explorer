// BundleExportGraphicSubcommand+Bulk.swift - The bulk form of bundle export-graphic
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// One figure of the bulk form, drawn and not yet written.
struct BundleExportGraphicBulkFigure {
    let line: ViewerGraphicRegionsFile.Line
    let region: ViewerGraphicRegion
    let name: String
    let figure: ViewerGraphicFigure
    let degraded: [ViewerFigureOmission]
    let rendering: ViewerFigureRendering
}

extension BundleExportGraphicSubcommand {
    /// The bulk form (ARCH ruling B10 3.2, BIO ruling Q-G3 item 4). One figure for each region line of the BED file,
    /// written into the new folder `--output` names, which is staged and published once with one record that lists
    /// every figure as an output and the BED file as an input. The bundle's manifest is read once for all regions,
    /// and every refusal comes before any write.
    func exportBulk(
        events: CLIEventEmitter, render: Render, invocation: ViewerExportInvocation, regionsURL: URL,
        runClock: ProvenanceRunClock
    ) async throws -> ViewerExportLeafOutcome {
        let settings = graphic.settings
        let folderURL = URL(fileURLWithPath: invocation.output, isDirectory: true).standardizedFileURL
        let fileName = regionsURL.lastPathComponent
        let bundle: ViewerGraphicBundle
        let trackIDs: [String]
        var planned: [(line: ViewerGraphicRegionsFile.Line, region: ViewerGraphicRegion, name: String)] = []
        do {
            bundle = try ViewerGraphicBundle(url: URL(fileURLWithPath: invocation.input, isDirectory: true))
            trackIDs = try ViewerGraphicExport.trackIDs(settings.tracks, in: bundle)
            var named: [String: Int] = [:]
            for line in try ViewerGraphicRegionsFile.lines(of: regionsURL) {
                let region: ViewerGraphicRegion
                do {
                    region = try bundle.region(contig: line.contig, start: line.start, end: line.end)
                } catch let refusal as ViewerGraphicRefusal {
                    throw ViewerGraphicRefusal("Line \(line.number) of \(fileName) cannot be drawn. \(refusal.message)")
                }
                let name = line.fileName(format: settings.format)
                // A Mac volume stores names that differ only in capitals or in Unicode form as one file.
                let key = name.precomposedStringWithCanonicalMapping.lowercased()
                if let earlier = named[key] {
                    throw ViewerGraphicRefusal(
                        "Lines \(earlier) and \(line.number) of \(fileName) both name the image \(name), counting "
                            + "capital and small letters as the same, since a Mac stores them as one file. "
                            + "Give each line its own name in column 4."
                    )
                }
                named[key] = line.number
                planned.append((line, region, name))
            }
        } catch let refusal as ViewerGraphicRefusal {
            throw ViewerExportRefusal(refusal.message)
        }
        let viewStateURL = settings.viewState.map { URL(fileURLWithPath: $0) }
        var viewState: ViewerGraphicViewState?
        if let viewStateURL {
            do {
                viewState = try ViewerGraphicViewState.read(from: viewStateURL)
            } catch {
                throw ViewerExportRefusal("The view-state file at \(viewStateURL.path) cannot be read. \(error.localizedDescription)")
            }
        }
        try Self.refuseUnsafeFolder(folderURL, inputs: [bundle.manifestURL, regionsURL] + (viewStateURL.map { [$0] } ?? []))

        let pixelScale = Double(settings.format == .pdf ? 1 : settings.scale ?? ViewerGraphicExport.defaultScale)
        var figures: [BundleExportGraphicBulkFigure] = []
        var inputURLs: [URL] = []
        for plan in planned {
            try Task.checkCancellation()
            let figure = try await ViewerGraphicExport.figure(
                bundle: bundle, region: plan.region, trackIDs: trackIDs, settings: settings,
                viewState: viewState, viewStateURL: viewStateURL
            )
            let rendering = try render(figure.scene, settings.format, pixelScale)
            let degraded = ViewerGraphicExport.degradedFacts(of: figure.scene)
            BundleExportGraphicRecord.report(degraded, image: plan.name, events: events, quiet: globalOptions.quiet)
            for url in figure.inputURLs where !inputURLs.contains(url) {
                inputURLs.append(url)
            }
            figures.append(BundleExportGraphicBulkFigure(
                line: plan.line, region: plan.region, name: plan.name, figure: figure, degraded: degraded,
                rendering: rendering
            ))
        }
        inputURLs.append(regionsURL)
        let record = BundleExportGraphicRecord.bulk(
            settings: settings, trackIDs: trackIDs, figures: figures, pixelScale: pixelScale, folderURL: folderURL
        )
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeFolderAtomically(.cliLeaf(
            workflowName: ViewerGraphicExport.workflowName,
            sourceURLs: inputURLs,
            outputURL: folderURL,
            outputFormat: BundleExportGraphicRecord.fileFormat(settings.format),
            argv: invocation.canonicalArgv(),
            explicitOptions: record.explicitOptions,
            defaults: record.defaults,
            resolved: record.resolved,
            runClock: runClock
        )) { stagedFolder in
            for figure in figures {
                try figure.rendering.data.write(to: stagedFolder.appendingPathComponent(figure.name))
            }
            try ViewerExportLeaf.checkpointAfterStaging()
            return figures.map(\.name)
        }
        return ViewerExportLeafOutcome(
            outputURL: folderURL, message: "Exported \(figures.count) images to \(folderURL.lastPathComponent)"
        )
    }

    /// The bulk form writes a new folder, so a folder or file already at the path is refused even with `--force`.
    static func refuseUnsafeFolder(_ folderURL: URL, inputs: [URL]) throws {
        try ViewerExportLeaf.refuseUnsafeOutput(folderURL, inputs: inputs, force: true)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            throw ViewerExportRefusal(
                "Something already exists at \(folderURL.path). The regions file writes a new folder, so choose a path that does not exist."
            )
        }
    }
}

extension BundleExportGraphicRecord {
    /// The record of the bulk form. `explicitOptions` and `defaults` are the command's. `resolved` holds the
    /// settings every figure shares, `figures` with each figure's own resolved values, its file name and its BED
    /// line, and `degraded` with every figure's facts, each naming its file.
    static func bulk(
        settings: ViewerGraphicExport.Settings, trackIDs: [String], figures: [BundleExportGraphicBulkFigure],
        pixelScale: Double, folderURL: URL
    ) -> BundleExportGraphicRecord {
        let perFigure = figures.map { item -> (BundleExportGraphicBulkFigure, [String: ParameterValue]) in
            var own = settings
            own.region = item.region.display
            own.regionsFile = nil
            let record = BundleExportGraphicRecord(
                settings: own, region: item.region, trackIDs: trackIDs, figure: item.figure, degraded: item.degraded,
                rendering: item.rendering, pixelScale: pixelScale,
                outputURL: folderURL.appendingPathComponent(item.name), force: false
            )
            var resolved = record.resolved
            resolved["output"] = .string(item.name)
            resolved["bedLine"] = .integer(item.line.number)
            return (item, resolved)
        }
        let first = BundleExportGraphicRecord(
            settings: settings, region: figures[0].region, trackIDs: trackIDs, figure: figures[0].figure,
            degraded: figures[0].degraded, rendering: figures[0].rendering, pixelScale: pixelScale,
            outputURL: folderURL, force: false
        )
        var resolved: [String: ParameterValue] = [:]
        for key in ["regionConvention", "format", "theme", "includeRuler", "rendererVersion", "sceneFormatVersion", "hostOSBuild"] {
            resolved[key] = first.resolved[key]
        }
        resolved["figureCount"] = .integer(figures.count)
        resolved["figures"] = .array(perFigure.map { .dictionary($0.1) })
        resolved["degraded"] = .array(perFigure.flatMap { item, own -> [ParameterValue] in
            guard case .array(let facts)? = own["degraded"] else { return [] }
            return facts.map { fact in
                guard case .dictionary(var entry) = fact else { return fact }
                entry["output"] = .string(item.name)
                return .dictionary(entry)
            }
        })
        return BundleExportGraphicRecord(
            explicitOptions: first.explicitOptions, defaults: first.defaults, resolved: resolved
        )
    }
}
