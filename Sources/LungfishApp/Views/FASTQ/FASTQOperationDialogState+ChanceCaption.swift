// FASTQOperationDialogState+ChanceCaption.swift - The dialog's words and choices about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The person's Keep Unchecked Samples in the Demultiplex Barcodes tool, and preflight's answer for the settings it was
/// asked about (DEMUX-FLOOR-SATURATED-KIT, BIO-SATKIT-FLUIDIGM item 3).
struct FASTQDemultiplexChanceCheck: Equatable {
    /// The settings preflight's chance check reads, as the dialog's command gives them to `lungfish-cli fastq demultiplex`.
    struct Settings: Hashable, Sendable {
        var engine: DemultiplexEngine
        var kitID: String?
        var definitionPath: String?
        var location: String
        var errorRate: String
        var maxDistanceFrom5Prime: Int
        var maxDistanceFrom3Prime: Int
        /// The chosen inputs, whose read names the Exact Bare Barcode check reads.
        var inputPaths: [String] = []
    }

    var keepsUncheckedSamples = false
    var answered: Settings?
    var canRefuse = false

    /// Whether preflight can refuse a run with these settings, with Cutadapt as one the chance check cannot judge, and with
    /// Exact Bare Barcode as one whose read names carry two or more of the kit's barcodes in some chosen input
    /// (DEMUX-EXACT-BARE-NO-FLOOR). It loads the kit and builds the config as the command does, then asks preflight's own
    /// predicate. A kit or definition that does not load, or whose lines preflight refuses for another reason, is not one
    /// the chance check refuses. The read names are known only once the first names of each input are read, so the box
    /// shows a moment after the engine is chosen, as it does for a kit.
    static func canRefuse(_ settings: Settings, inputs: [URL]) async -> Bool {
        guard let kit = kit(settings) else { return false }
        if settings.engine == .exactBareBarcode {
            for input in inputs {
                let config = DemultiplexConfig(
                    inputURL: input, barcodeKit: kit, outputDirectory: FileManager.default.temporaryDirectory,
                    engine: .exactBareBarcode
                )
                if await DemultiplexingPipeline().exactBareCanRefuseReadNames(config: config) { return true }
            }
            return false
        }
        guard settings.engine == .cutadapt else { return false }
        let location: BarcodeLocation
        switch settings.location {
        case "fiveprime": location = .fivePrime
        case "threeprime": location = .threePrime
        default: location = .bothEnds
        }
        let config = DemultiplexConfig(
            inputURL: inputs.first ?? FileManager.default.temporaryDirectory, barcodeKit: kit,
            outputDirectory: FileManager.default.temporaryDirectory,
            barcodeLocation: location, errorRate: Double(settings.errorRate),
            maxDistanceFrom5Prime: settings.maxDistanceFrom5Prime, maxDistanceFrom3Prime: settings.maxDistanceFrom3Prime
        )
        return (try? await DemultiplexingPipeline().chanceCheckCanRefuseKit(config: config)) ?? false
    }

    /// The built-in kit or the definition the settings name, loaded as the command loads it, or nil when it does not load.
    static func kit(_ settings: Settings) -> BarcodeKitDefinition? {
        let kit: BarcodeKitDefinition
        if let id = settings.kitID, let builtIn = BarcodeKitRegistry.kit(byID: id) {
            kit = builtIn
        } else if let path = settings.definitionPath {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let loaded = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            kit = loaded
        } else {
            return nil
        }
        return kit
    }
}

extension FASTQOperationDialogState {
    /// The caption under the engine's explanation while Exact Bare Barcode is picked (DEMUX-EXACT-BARE-NO-FLOOR, ruling
    /// UX-EXACT-BARE-WORDS). It sits in this file because `FASTQOperationDialogState.swift` may not grow (file-size ratchet).
    static let demultiplexExactBareChanceCaption =
        "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence."

    var demultiplexEngineChanceCaption: String? {
        demultiplexEngine == .exactBareBarcode ? Self.demultiplexExactBareChanceCaption : nil
    }

    /// True when the cutadapt engine will search the selected built-in kit as
    /// the platform's full adapter+barcode construct, so the Location picker
    /// and the 5'/3' Distance fields have no effect and are hidden.
    var demultiplexKitUsesPlatformConstruct: Bool {
        guard demultiplexEngine == .cutadapt,
              demultiplexBarcodeSource == .builtinKit,
              let kit = BarcodeKitRegistry.kit(byID: demultiplexKitID) else { return false }
        return kit.searchesFullPlatformConstruct
    }

    /// The caption under Keep Unchecked Samples (words for the UX review).
    static let demultiplexKeepUncheckedSamplesCaption =
        "About half of all reads or more match a barcode of this kit by chance, so the check for chance matches cannot judge the samples, and the run is refused. Choose Keep Unchecked Samples to make the sample files anyway, then check each sample against your sample sheet."

    /// The caption under Keep Unchecked Samples for the built-in Fluidigm Access Array kit, which cutadapt searches anywhere
    /// in the read. It names the routes made for that kit, as the refusal does (BIO-SATKIT-FLUIDIGM item 4), since a person
    /// who ticks the box never reads the refusal.
    static let demultiplexKeepUncheckedSamplesFluidigmCaption =
        "Cutadapt searches each barcode of this kit anywhere in the read, so about half of all reads or more match one of them by chance. The check for chance matches cannot judge the samples, and the run is refused. For Fluidigm barcodes in ONT reads, use ONT Fluidigm Sample Split. For reads whose index is in the read names, choose the engine Read Names. Choose Keep Unchecked Samples only to make the sample files anyway, then check each sample against your sample sheet."

    /// The caption under Keep Unchecked Samples with Exact Bare Barcode, when the read names carry the kit's barcodes
    /// (DEMUX-EXACT-BARE-NO-FLOOR, words for the UX review).
    static let demultiplexExactBareKeepUncheckedSamplesCaption =
        "The read names carry barcodes of this kit, so Exact Bare Barcode would find them in the read sequences only by chance, and the run is refused. Choose the engine Read Names to split the reads by their names. Choose Keep Unchecked Samples only if the read sequences carry these barcodes too, then check each sample against your sample sheet."

    /// The caption under Keep Unchecked Samples for the chosen engine.
    var demultiplexKeepUncheckedSamplesCaptionForEngine: String {
        demultiplexEngine == .exactBareBarcode
            ? Self.demultiplexExactBareKeepUncheckedSamplesCaption : Self.demultiplexKeepUncheckedSamplesCaption
    }

    /// The settings the chance check of the chosen kit reads, with the error rate written as the command writes it. The
    /// rows ask again when they change (`FASTQDemultiplexChanceRows`).
    var demultiplexChanceCheckSettings: FASTQDemultiplexChanceCheck.Settings {
        FASTQDemultiplexChanceCheck.Settings(
            engine: demultiplexEngine,
            kitID: demultiplexBarcodeSource == .builtinKit ? demultiplexKitID : nil,
            definitionPath: demultiplexBarcodeSource == .customDefinition ? auxiliaryInputURL(for: .barcodeDefinition)?.path : nil,
            location: demultiplexLocation,
            errorRate: String(format: "%.2f", demultiplexErrorRate),
            maxDistanceFrom5Prime: demultiplexMaxDistanceFrom5Prime,
            maxDistanceFrom3Prime: demultiplexMaxDistanceFrom3Prime,
            inputPaths: selectedInputURLs.map(\.path)
        )
    }

    /// Whether the dialog shows Keep Unchecked Samples: with Cutadapt, exactly when preflight's predicate says it can
    /// refuse the chosen kit (`DemultiplexingPipeline.chanceCheckCanRefuseKit`), with Exact Bare Barcode, exactly when it
    /// says the read names of a chosen input carry the kit's barcodes (`exactBareCanRefuseReadNames`), and only for the
    /// settings it was asked.
    var showsDemultiplexKeepUncheckedSamples: Bool {
        (demultiplexEngine == .cutadapt || demultiplexEngine == .exactBareBarcode) && demultiplexChanceCheck.canRefuse
            && demultiplexChanceCheck.answered == demultiplexChanceCheckSettings
    }

    /// The choice the request carries, true only while the box shows and is ticked, so the command names the flag only then.
    var demultiplexKeepUncheckedSamplesForRun: Bool? {
        showsDemultiplexKeepUncheckedSamples && demultiplexChanceCheck.keepsUncheckedSamples ? true : nil
    }

    /// Asks preflight's predicate, off the main actor, whether it can refuse the chosen kit, and keeps the answer for the
    /// settings it asked about. An answer that comes after the settings changed is dropped.
    func refreshDemultiplexChanceCheck() async {
        let settings = demultiplexChanceCheckSettings
        let inputs = selectedInputURLs
        let canRefuse = await Task.detached(priority: .userInitiated) {
            await FASTQDemultiplexChanceCheck.canRefuse(settings, inputs: inputs)
        }.value
        guard !Task.isCancelled, settings == demultiplexChanceCheckSettings else { return }
        demultiplexChanceCheck.answered = settings
        demultiplexChanceCheck.canRefuse = canRefuse
    }
}
