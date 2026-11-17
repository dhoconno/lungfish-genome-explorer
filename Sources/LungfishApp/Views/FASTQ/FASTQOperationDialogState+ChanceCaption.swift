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
    }

    var keepsUncheckedSamples = false
    var answered: Settings?
    var canRefuse = false

    /// Whether preflight can refuse a run with these settings as one the chance check cannot judge. It loads the kit and
    /// builds the config as the command does, then asks preflight's own predicate. A kit or definition that does not
    /// load, or whose lines preflight refuses for another reason, is not one the chance check refuses.
    static func canRefuse(_ settings: Settings, input: URL) async -> Bool {
        guard settings.engine == .cutadapt else { return false }
        let kit: BarcodeKitDefinition
        if let id = settings.kitID, let builtIn = BarcodeKitRegistry.kit(byID: id) {
            kit = builtIn
        } else if let path = settings.definitionPath {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let loaded = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent)
            else { return false }
            kit = loaded
        } else {
            return false
        }
        let location: BarcodeLocation
        switch settings.location {
        case "fiveprime": location = .fivePrime
        case "threeprime": location = .threePrime
        default: location = .bothEnds
        }
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: kit, outputDirectory: FileManager.default.temporaryDirectory,
            barcodeLocation: location, errorRate: Double(settings.errorRate),
            maxDistanceFrom5Prime: settings.maxDistanceFrom5Prime, maxDistanceFrom3Prime: settings.maxDistanceFrom3Prime
        )
        return (try? await DemultiplexingPipeline().chanceCheckCanRefuseKit(config: config)) ?? false
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
            maxDistanceFrom3Prime: demultiplexMaxDistanceFrom3Prime
        )
    }

    /// Whether the dialog shows Keep Unchecked Samples: with Cutadapt, exactly when preflight's predicate says it can
    /// refuse the chosen kit (`DemultiplexingPipeline.chanceCheckCanRefuseKit`), and only for the settings it was asked.
    var showsDemultiplexKeepUncheckedSamples: Bool {
        demultiplexEngine == .cutadapt && demultiplexChanceCheck.canRefuse
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
        let input = selectedInputURLs.first ?? FileManager.default.temporaryDirectory
        let canRefuse = await Task.detached(priority: .userInitiated) {
            await FASTQDemultiplexChanceCheck.canRefuse(settings, input: input)
        }.value
        guard !Task.isCancelled, settings == demultiplexChanceCheckSettings else { return }
        demultiplexChanceCheck.answered = settings
        demultiplexChanceCheck.canRefuse = canRefuse
    }
}
