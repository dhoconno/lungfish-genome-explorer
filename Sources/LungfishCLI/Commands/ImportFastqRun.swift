// ImportFastqRun.swift - The detection, the unpaired-reads check and the import that import fastq and fetch sra download --bundle both run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// What a FASTQ import reports through (Phase 2.10 lane A45 M3, ruling A45-M3 section 1 and the
/// manager's answer on the nested child).
///
/// `import fastq` reports through ``ImportFastqReporter``, which prints the import's own events.
/// `fetch sra download --bundle` runs the same import in its own process and reports through a
/// reporter that maps the import's log events onto its own progress, so the command prints only its
/// own events and starts no second process or event stream.
protocol FASTQImportReporting: Sendable {
    /// One line of human text.
    func text(_ line: String)
    /// A warning of pair detection or of the third-file check.
    func pairingNotice(sample: String, message: String)
    /// One log event of the importer.
    func log(_ event: ImportLogEvent)
    /// Ends the run with the error as human text and a failed event, and gives the exit code to throw.
    func fail(_ message: String, detail: String?, exitCode: CLIExitCode) -> ExitCode
    /// A failed event for a failure whose human text was already printed.
    func failedEvent(_ message: String)
}

extension ImportFastqReporter: FASTQImportReporting {}

/// How the import's task follows a SIGTERM.
enum FASTQImportCancellation: Sendable {
    /// The command listens for SIGTERM during the import, as `import fastq` does. A second SIGTERM
    /// ends the process at once.
    case installsSIGTERMHandler
    /// The caller already listens and cancels its own task, which the import's task follows.
    case followsCallingTask
}

/// One FASTQ import, from the paths it is given to the batch's result. `import fastq` builds it from
/// its flags and `fetch sra download --bundle` from the files it downloaded and the
/// ``ImportFastqOptions`` it embeds. Both call ``run(reporter:cancellation:)``.
struct FASTQImportRun {
    var input: [String]
    var samplesheet: String?
    /// The project folder the import writes `Imports/<sample>.lungfishfastq` into.
    var project: String
    var recipe = "none"
    var qualityBinning = "none"
    var logDir: String?
    var dryRun = false
    var platform = "auto"
    var pairing = "auto"
    var noOptimizeStorage = false
    var clumpingTool: String?
    var compression = "balanced"
    var force = false
    var name: String?
    var recursive = false
    var threads: Int?
    /// The clumpify heap `--clumpify-heap-gb` pins, in GB.
    var clumpifyHeapGB: Int?
    var quiet = false
    var useColors = false

    /// Detects the samples, applies `pairing` and `name`, checks a run's unpaired reads, resolves the
    /// settings and imports. It prints the detected samples as human text and reports the importer's
    /// log events through `reporter`. It never prints a start, summary or complete line, which the
    /// calling command owns.
    ///
    /// - Returns: The batch's result, or nil for a dry run, whose lines are already printed.
    /// - Throws: The exit code of a failure, after `reporter` printed its failed line.
    func run(reporter: some FASTQImportReporting, cancellation: FASTQImportCancellation) async throws -> FASTQBatchImporter.ImportResult? {
        if let clumpifyHeapGB, let problem = clumpifyHeapProblem(clumpifyHeapGB) {
            throw reporter.fail(problem, detail: nil, exitCode: .inputError)
        }

        let formatter = TerminalFormatter(useColors: useColors)
        guard !input.isEmpty || samplesheet != nil else {
            throw reporter.fail("At least one input path or --samplesheet is required.", detail: nil, exitCode: .inputError)
        }
        guard !(samplesheet != nil && !input.isEmpty) else {
            throw reporter.fail("Pass either FASTQ input paths or --samplesheet, not both.", detail: nil, exitCode: .inputError)
        }

        // MARK: Detect pairs

        let detectedPairs: [SamplePair]
        // Why detection left a file of another folder unpaired. Only a
        // recursive scan and explicit files can span folders.
        var pairingNotices: [FASTQBatchImporter.PairingNotice] = []
        let fm = FileManager.default

        if let samplesheet {
            let sheetURL = URL(fileURLWithPath: samplesheet)
            guard fm.fileExists(atPath: sheetURL.path) else {
                throw reporter.fail("Sample sheet not found: \(samplesheet)", detail: nil, exitCode: .inputError)
            }
            do {
                detectedPairs = try FASTQSampleSheet.parse(url: sheetURL).samplePairs()
            } catch {
                throw reporter.fail("Could not parse sample sheet: \(error.localizedDescription)", detail: nil, exitCode: .formatError)
            }
        } else if input.count == 1 {
            // Single argument: could be a directory or a single file
            let inputURL = URL(fileURLWithPath: input[0])
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)

            if exists && isDirectory.boolValue {
                do {
                    if recursive {
                        let detection = try FASTQBatchImporter.detectingPairsFromDirectoryRecursive(inputURL)
                        detectedPairs = detection.samples
                        pairingNotices = detection.notices
                    } else {
                        detectedPairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
                    }
                } catch let batchError as BatchImportError {
                    throw reporter.fail(batchError.errorDescription ?? batchError.localizedDescription, detail: nil, exitCode: .inputError)
                } catch {
                    // Any other error of the scan, such as a folder this user may not list, still ends the
                    // run in a failed line. ArgumentParser reports the error as before.
                    reporter.failedEvent(error.localizedDescription)
                    throw error
                }
            } else {
                guard exists else {
                    throw reporter.fail("Input not found: \(input[0])", detail: nil, exitCode: .inputError)
                }
                detectedPairs = FASTQBatchImporter.detectPairs(from: [inputURL])
            }
        } else {
            // Multiple arguments: treat as explicit file paths
            var fileURLs: [URL] = []
            for path in input {
                let url = URL(fileURLWithPath: path)
                guard fm.fileExists(atPath: url.path) else {
                    throw reporter.fail("Input file not found: \(path)", detail: nil, exitCode: .inputError)
                }
                fileURLs.append(url)
            }
            let detection = FASTQBatchImporter.detectingPairs(from: fileURLs)
            detectedPairs = detection.samples
            pairingNotices = detection.notices
        }

        // MARK: Apply --pairing

        guard let pairingChoice = FASTQBatchImporter.ImportPairing(rawValue: pairing.lowercased()) else {
            throw reporter.fail("Unknown pairing value '\(pairing)'. Valid: auto, single, paired, interleaved", detail: nil, exitCode: .inputError)
        }
        var samples = FASTQBatchImporter.applyPairing(pairingChoice, to: detectedPairs)

        // MARK: Apply --name override

        // --name names the one sample detection made. It applies before
        // the check below, so when the check leaves a run's third file
        // out, the pair and that file both take the name, the pair
        // imports under it and the file's sample is skipped, as the
        // warning says. Applied after the check, --name refused such a
        // run after printing a warning about an import that never ran
        // (finding F11-N2).
        if let name {
            guard samples.count == 1 else {
                throw reporter.fail("--name requires exactly one detected sample (found \(samples.count)).", detail: nil, exitCode: .inputError)
            }
            samples = [samples[0].named(name)]
        }

        // A run's third file stays joined to its pair only when the first
        // reads bear the join out. Otherwise the import skips the third
        // file's sample, and a warning says why. The window runs this
        // command with --format json, so its Operations row logs the notice.
        let unpairedReadsCheck = FASTQBatchImporter.checkingUnpairedReads(samples)
        let effectivePairs = unpairedReadsCheck.samples
        // Why detection left a file of another folder unpaired, then the
        // check's warnings. single and interleaved split every pair, so a
        // notice about a pair detection did not make says nothing to them.
        let warnings = (pairingChoice.keepsDetectedPairs ? pairingNotices.map(\.event) : [])
            + unpairedReadsCheck.warnings

        // MARK: Print detected pairs

        reporter.text(formatter.header("FASTQ Import"))
        reporter.text("")
        reporter.text(formatter.info("Detected \(effectivePairs.count) sample(s):"))
        for (i, pair) in effectivePairs.enumerated() {
            let index = String(format: "%3d", i + 1)
            if let r2 = pair.r2 {
                reporter.text("  \(index). \(pair.sampleName)  [paired]")
                reporter.text("        R1: \(pair.r1.lastPathComponent)")
                reporter.text("        R2: \(r2.lastPathComponent)")
                if let unpaired = pair.unpaired {
                    reporter.text("        Unpaired: \(unpaired.lastPathComponent)")
                }
            } else {
                reporter.text("  \(index). \(pair.sampleName)  [single-end]")
                reporter.text("        R1: \(pair.r1.lastPathComponent)")
            }
        }
        reporter.text("")
        if !warnings.isEmpty {
            for case .notice(let sample, let message) in warnings {
                reporter.pairingNotice(sample: sample, message: message)
            }
            reporter.text("")
        }

        // MARK: Resolve platform request

        guard let platformRequest = ImportPlatformRequest(cliValue: platform) else {
            throw reporter.fail(
                "Unknown platform '\(platform)'. Valid: \(ImportPlatformRequest.cliValues.joined(separator: ", "))",
                detail: nil,
                exitCode: .inputError
            )
        }

        // MARK: Dry-run exit

        if dryRun {
            for pair in effectivePairs {
                let resolution = FASTQBatchImporter.resolvePlatform(for: pair, request: platformRequest)
                reporter.text("  \(pair.sampleName): \(resolution.summaryLine)")
            }
            reporter.text(formatter.info("Dry-run mode — no files were imported."))
            return nil
        }

        // MARK: Resolve recipe

        var newRecipe: Recipe? = nil
        var oldRecipe: ProcessingRecipe? = nil
        if recipe.lowercased() != "none" {
            do {
                let resolvedRecipe = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: recipe)
                newRecipe = resolvedRecipe.newRecipe
                oldRecipe = resolvedRecipe.legacyRecipe
            } catch let unavailable as ImportCommand.FastqSubcommand.RecipeFileUnavailable {
                throw reporter.fail(unavailable.localizedDescription, detail: nil, exitCode: .inputError)
            } catch let batchError as BatchImportError {
                throw reporter.fail(batchError.errorDescription ?? batchError.localizedDescription, detail: nil, exitCode: .inputError)
            } catch {
                reporter.failedEvent(error.localizedDescription)
                throw error
            }
        }

        // MARK: Resolve quality binning

        let binningScheme: QualityBinningScheme
        switch qualityBinning.lowercased() {
        case "illumina4":
            binningScheme = .illumina4
        case "eightlevel", "eight_level", "eight-level":
            binningScheme = .eightLevel
        case "none":
            binningScheme = .none
        default:
            throw reporter.fail(
                "Unknown quality-binning value '\(qualityBinning)'. Valid: illumina4, eightLevel, none", detail: nil, exitCode: .inputError
            )
        }

        // MARK: Resolve compression level

        guard let compLevel = CompressionLevel(rawValue: compression.lowercased()) else {
            throw reporter.fail("Unknown compression '\(compression)'. Valid: fast, balanced, maximum", detail: nil, exitCode: .inputError)
        }

        // MARK: Resolve clumping tool

        let requestedClumpingTool: ClumpingTool?
        do {
            requestedClumpingTool = noOptimizeStorage
                ? ClumpingTool.none
                : try clumpingTool.map(ImportCommand.FastqSubcommand.parseClumpingTool)
        } catch {
            throw reporter.fail(
                "Unknown clumping-tool value '\(clumpingTool ?? "")'. Valid: auto, bbtools, trim-galore, none", detail: nil, exitCode: .inputError
            )
        }

        // MARK: Build config

        let projectURL = URL(fileURLWithPath: project)
        let logDirURL = logDir.map { URL(fileURLWithPath: $0) }
        let threadCount = threads ?? FASTQBatchImporter.ImportConfig.hostThreadCount

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            platform: platformRequest,
            recipe: oldRecipe,
            newRecipe: newRecipe,
            qualityBinning: binningScheme,
            optimizeStorage: ImportCommand.FastqSubcommand.requestedOptimizeStorage(
                noOptimizeStorage: noOptimizeStorage,
                clumpingTool: requestedClumpingTool
            ),
            clumpingTool: requestedClumpingTool,
            compressionLevel: compLevel,
            threads: threadCount,
            logDirectory: logDirURL,
            forceReimport: force,
            pairing: pairingChoice,
            threadsSource: threads == nil ? .host : .option,
            clumpifyHeapGB: clumpifyHeapGB
        )

        // A storage tool that cannot store the recipe's output fails only
        // after the whole recipe has run, so the pair is refused here.
        if let refusal = FASTQBatchImporter.storageToolRefusal(config: config) {
            throw reporter.fail(
                refusal + " Pass --clumping-tool bbtools or --no-optimize-storage.", detail: nil, exitCode: .inputError
            )
        }

        let isQuiet = quiet
        try await ImportCommand.FastqSubcommand.installRequiredManagedDatabases(
            requiredIDs: ImportCommand.FastqSubcommand.requiredManagedDatabaseIDs(legacyRecipe: oldRecipe, newRecipe: newRecipe),
            formatter: formatter,
            isQuiet: isQuiet,
            emit: { reporter.text($0) },
            failure: { reporter.failedEvent($0) }
        )

        // MARK: Run import

        if !isQuiet {
            reporter.text(formatter.info("Starting import with \(threadCount) thread(s)…"))
            reporter.text("")
        }

        // SIGTERM (the window's Cancel) cancels the import, so it removes
        // its staging bundle and workspace before the command exits. It
        // listens before the task starts, and a SIGTERM caught before then
        // cancels the task as soon as it exists. A second SIGTERM ends the
        // command at once. The batch itself says whether a cancel stopped
        // it, so a SIGTERM after the last sample was published does not
        // turn a finished import into a cancelled one. A caller that listens
        // itself (`followsCallingTask`) cancels its own task, which the import
        // follows.
        let pendingCancel = PendingTaskCancel<FASTQBatchImporter.ImportResult>()
        let termination: SIGTERMCancellation? = cancellation == .installsSIGTERMHandler
            ? SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
            : nil
        let importTask = Task {
            await FASTQBatchImporter.runBatchImport(
                pairs: effectivePairs,
                config: config,
                log: { event in reporter.log(event) }
            )
        }
        pendingCancel.attach(importTask)
        let result = await withTaskCancellationHandler {
            await importTask.value
        } onCancel: {
            importTask.cancel()
        }
        termination?.end()
        if result.cancelled {
            throw reporter.fail("Import cancelled", detail: nil, exitCode: .cancelled)
        }
        return result
    }
}

/// Why `--clumpify-heap-gb` cannot be `gigabytes`, or nil when it can. Clumpify's heap is multiplied by a GiB in bytes
/// where it is planned and launched, so a value no host holds overflowed and trapped. The limit is this host's
/// physical memory in GiB, and the message names it (CHTC lane L5-RECORDS, Fix 6).
private func clumpifyHeapProblem(
    _ gigabytes: Int,
    physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
) -> String? {
    let limit = max(1, Int(clamping: physicalMemoryBytes / 1_073_741_824))
    guard gigabytes < 1 || gigabytes > limit else { return nil }
    return "--clumpify-heap-gb must be between 1 and \(limit), this host's physical memory in GB."
}
