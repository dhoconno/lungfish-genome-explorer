// BundleExportGraphicSubcommand.swift - lungfish-cli bundle export-graphic
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Draws one region of a reference bundle as a PNG, JPEG, TIFF or PDF image with its record beside it (Phase 2.13
/// lane 13.30, owner rows O17 and O18, ARCH ruling B10 section 3).
///
/// The figure is drawn from the bundle's files with no window server, so images can be made in bulk from scripts.
/// The app's File > Export > Image of a bundle runs this leaf behind its Operations row. The record names the
/// manifest and each file a drawn track read, the region as passed and as drawn, every pixel setting and every limit
/// that hid data from the image.
struct BundleExportGraphicSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-graphic",
        abstract: "Draw one region of a bundle as an image with provenance"
    )

    @Argument(help: "The reference bundle to draw")
    var bundlePath: String

    @OptionGroup var graphic: ViewerExportOptions.Graphic
    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        ViewerGraphicExport.invocation(
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            settings: graphic.settings,
            outputURL: URL(fileURLWithPath: output.path),
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Drawing \(graphic.region) of \(URL(fileURLWithPath: bundlePath).lastPathComponent)."
        ) { events in
            try await command.export(events: events)
        }
    }

    /// The rasterizer call the export makes. A test passes its own to force a PDF the normalizer keeps as written.
    typealias Render = (ViewerFigureScene, ViewerFigureFormat, Double) throws -> ViewerFigureRendering

    /// The export, which refuses before it writes and writes the image and its record in one transaction.
    func export(
        events: CLIEventEmitter,
        render: Render = ViewerFigureRasterizer.renderReporting(_:format:pixelScale:)
    ) async throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let settings = graphic.settings
        let outputURL = URL(fileURLWithPath: invocation.output)
        guard let parsed = GenomicRegionArgument.parseRegion(settings.region) else {
            throw ViewerExportRefusal(
                "The region \(settings.region) is not contig:start-end with 1 <= start <= end. Pass a region such as chr1:101-200."
            )
        }
        let bundle: ViewerGraphicBundle
        let region: ViewerGraphicRegion
        let trackIDs: [String]
        var viewState: ViewerGraphicViewState?
        let viewStateURL = settings.viewState.map { URL(fileURLWithPath: $0) }
        do {
            bundle = try ViewerGraphicBundle(url: URL(fileURLWithPath: invocation.input, isDirectory: true))
            region = try bundle.region(contig: parsed.contig, start: parsed.start, end: parsed.end)
            trackIDs = try ViewerGraphicExport.trackIDs(settings.tracks, in: bundle)
        } catch let refusal as ViewerGraphicRefusal {
            throw ViewerExportRefusal(refusal.message)
        }
        if let viewStateURL {
            do {
                viewState = try ViewerGraphicViewState.read(from: viewStateURL)
            } catch {
                throw ViewerExportRefusal("The view-state file at \(viewStateURL.path) cannot be read. \(error.localizedDescription)")
            }
        }
        try ViewerExportLeaf.refuseUnsafeOutput(
            outputURL, inputs: [bundle.manifestURL] + (viewStateURL.map { [$0] } ?? []), force: invocation.force
        )
        let figure = try await ViewerGraphicExport.figure(
            bundle: bundle, region: region, trackIDs: trackIDs, settings: settings,
            viewState: viewState, viewStateURL: viewStateURL
        )
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: figure.inputURLs, force: invocation.force)
        try Task.checkCancellation()
        let pixelScale = Double(settings.format == .pdf ? 1 : settings.scale ?? ViewerGraphicExport.defaultScale)
        let rendering = try render(figure.scene, settings.format, pixelScale)
        let degraded = ViewerGraphicExport.degradedFacts(of: figure.scene)
        for fact in degraded {
            let line = "Warning: \(BundleExportGraphicRecord.warning(fact))"
            events.emitLog(.warning, line)
            if !globalOptions.quiet {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
        let record = BundleExportGraphicRecord(
            settings: settings, region: region, trackIDs: trackIDs, figure: figure, degraded: degraded,
            rendering: rendering, pixelScale: pixelScale, outputURL: outputURL, force: invocation.force
        )
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: ViewerGraphicExport.workflowName,
            sourceURLs: figure.inputURLs,
            outputURL: outputURL,
            outputFormat: BundleExportGraphicRecord.fileFormat(settings.format),
            argv: invocation.canonicalArgv(),
            explicitOptions: record.explicitOptions,
            defaults: record.defaults,
            resolved: record.resolved,
            runClock: runClock
        )) { stagedURL in
            try rendering.data.write(to: stagedURL)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        return ViewerExportLeafOutcome(outputURL: outputURL, message: "Exported \(outputURL.lastPathComponent)")
    }
}
