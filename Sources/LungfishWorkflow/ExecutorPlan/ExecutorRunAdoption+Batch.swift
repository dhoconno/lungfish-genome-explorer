// ExecutorRunAdoption+Batch.swift - The adopt of a returned batch into one project, all or nothing (CHTC C5 lane BADOPT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// One step of a batch adopt, in the order the adopt meets them (UX-c5 point 7). The CLI prints each message as text and
/// emits it as a `progress` event, and the Import Center card (lane US) shows the same events.
package enum ExecutorBatchAdoptProgress: Sendable, Equatable {
    /// The preflight of sample `index` (from 1) of `count`, before any bundle file exists.
    case checking(sample: String, index: Int, count: Int)
    /// The write of sample `index` of `count`, after every sample passed the preflight.
    case adopting(sample: String, index: Int, count: Int)
    /// Sample `index` of `count` is published as `bundle`.
    case adopted(sample: String, index: Int, count: Int, bundle: URL)

    /// `Checking 2 of 3: <sample>…`, `Adopting 2 of 3: <sample>…` and `Adopted <sample> as <bundle>` (AO:107's sentence).
    package var message: String {
        switch self {
        case let .checking(sample, index, count): return "Checking \(index) of \(count): \(sample)…"
        case let .adopting(sample, index, count): return "Adopting \(index) of \(count): \(sample)…"
        case let .adopted(sample, _, _, bundle): return "Adopted \(sample) as \(bundle.lastPathComponent)"
        }
    }

    /// The share of the run done at this step: the preflight writes nothing, and each written sample is one share.
    package var fraction: Double {
        switch self {
        case .checking: return 0
        case let .adopting(_, index, count): return Double(index - 1) / Double(max(count, 1))
        case let .adopted(_, index, count, _): return Double(index) / Double(max(count, 1))
        }
    }
}

/// One sample the batch preflight refused, named as the sample sheet names it (BI:13).
package struct ExecutorBatchAdoptRefusal: Sendable, Equatable {
    package let sample: String
    package let field: String
    /// The refusal without the one-folder adopt's closing "Nothing was imported.", which the end's message says once.
    package let cause: String
    package let gap: ExecutorAdoptRefusal.Gap?

    /// `<sample>: <reason>`, with the plain cause first when the job left out its record or its reads (UX-c5 point 7).
    package var line: String {
        switch gap {
        case .nothing: return "\(sample): its job returned nothing. \(cause)"
        case .reads: return "\(sample): its job returned no reads. \(cause)"
        case nil: return "\(sample): \(cause)"
        }
    }
}

/// How a batch adopt ended other than with every sample adopted, with the end's words (D2 a, UX-c5 point 7). No end reads
/// as a success with warnings: a refusal imports nothing, and a write failure or a cancel names the bundles it left.
package enum ExecutorBatchAdoptError: Error, Sendable, Equatable {
    /// The preflight refused these samples, in the batch's order, so nothing was imported.
    case refused(_ refusals: [ExecutorBatchAdoptRefusal], sampleCount: Int)
    /// A write failed after `adopted` bundles were published whole, and `notAdopted` names the samples left.
    case writeFailed(adopted: [URL], notAdopted: [String], sampleCount: Int, error: String)
    /// The run was cancelled after `adopted` bundles were published whole.
    case cancelled(adopted: [URL], notAdopted: [String], sampleCount: Int)
    /// The folder holds no sample folder, so it is no returned batch. The sentence ends "Nothing was imported."
    case notABatch(String)

    /// The way on after a refusal.
    package static let refusedWayOn = "Fix or rerun each refused sample on the Linux machine, then adopt the whole batch again."
    /// The way on after a write failure or a cancel, true because the adopt refuses a sample the project holds (D3).
    package static let restWayOn = "To adopt the rest, delete the imported bundles and adopt the batch again."

    /// The `failed` event's message.
    package var message: String {
        switch self {
        case let .refused(refusals, count):
            let verb = refusals.count == 1 ? "was" : "were"
            return "\(refusals.count) of \(ExecutorRunAdoption.samplesPhrase(count)) \(verb) refused. Nothing was imported."
        case let .writeFailed(adopted, _, count, error):
            guard !adopted.isEmpty else { return "The adopt failed. \(error) Nothing was imported." }
            return "The adopt failed after \(adopted.count) of \(ExecutorRunAdoption.samplesPhrase(count)). \(error)"
        case let .cancelled(adopted, _, count):
            guard !adopted.isEmpty else { return "Adopt cancelled. Nothing was imported." }
            return "Adopt cancelled after \(adopted.count) of \(ExecutorRunAdoption.samplesPhrase(count))."
        case let .notABatch(sentence):
            return sentence
        }
    }

    /// The `failed` event's detail: each refused sample's line and the way on, or the bundles made, the samples left and the
    /// way on. An end that made no bundle and refused none has no detail.
    package var detail: String? {
        switch self {
        case let .refused(refusals, _):
            return (refusals.map(\.line) + [Self.refusedWayOn]).joined(separator: "\n")
        case let .writeFailed(adopted, notAdopted, _, _), let .cancelled(adopted, notAdopted, _):
            guard !adopted.isEmpty else { return nil }
            return [
                "Imported: \(adopted.map(\.lastPathComponent).joined(separator: ", ")).",
                "Not imported: \(notAdopted.joined(separator: ", ")).",
                Self.restWayOn,
            ].joined(separator: "\n")
        case .notABatch:
            return nil
        }
    }
}

/// One sample folder of a returned batch: the batch folder's child the writer named for the sheet's sample, and the
/// returned plan folder the adopt reads in it.
struct ExecutorBatchSampleFolder: Sendable, Equatable {
    let name: String
    let folder: URL
}

/// A sample that passed the batch preflight, with the bundle it publishes.
struct ExecutorBatchCheckedSample: Sendable {
    let name: String
    let run: ExecutorAdoptedRun
    let bundle: URL
}

extension ExecutorRunAdoption {
    /// The folder a sample's job returns its record, reports and payload into (ARCH-c5 point 1).
    static let resultFolderName = "result"

    /// `1 sample` or `3 samples`, never `sample(s)` (UX-c5 point 1).
    package static func samplesPhrase(_ count: Int) -> String {
        count == 1 ? "1 sample" : "\(count) samples"
    }

    /// Whether the folder is one sample's returned plan folder, which the one-folder adopt reads: it holds `plan.json`.
    package static func isReturnedPlanFolder(_ folder: URL) -> Bool {
        holdsItem(at: folder.appendingPathComponent(planFileName))
    }

    /// Whether the folder is a returned batch, which the batch adopt reads: no `plan.json` of its own, and a sample folder.
    package static func isReturnedBatchFolder(_ folder: URL) -> Bool {
        !isReturnedPlanFolder(folder) && ((try? sampleFolders(in: folder))?.isEmpty == false)
    }

    /// Each sample folder of a batch, in name order: a child folder that holds `plan.json` or a `result` folder. The adopt
    /// reads `<sample>/result/` when it holds `plan.json`, and `<sample>/` otherwise. The submit folder's `logs/` and
    /// `staging/` hold neither, so they are no sample.
    static func sampleFolders(in batchFolder: URL) throws(ExecutorBatchAdoptError) -> [ExecutorBatchSampleFolder] {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: batchFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        } catch {
            throw .notABatch(
                "The folder \(batchFolder.lastPathComponent) cannot be read. \(error.localizedDescription) Nothing was imported."
            )
        }
        let samples = children.compactMap { child -> ExecutorBatchSampleFolder? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let result = child.appendingPathComponent(resultFolderName, isDirectory: true)
            if isReturnedPlanFolder(result) { return ExecutorBatchSampleFolder(name: child.lastPathComponent, folder: result) }
            guard isReturnedPlanFolder(child) || holdsItem(at: result) else { return nil }
            return ExecutorBatchSampleFolder(name: child.lastPathComponent, folder: child)
        }
        guard !samples.isEmpty else {
            throw .notABatch(
                "The folder \(batchFolder.lastPathComponent) holds no \(planFileName) and no sample folder with one, so it is "
                    + "neither a returned plan folder nor a returned batch. Nothing was imported."
            )
        }
        return samples.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The batch adopt (D2 a): every sample of `batchFolder` is adopted into `projectDirectory`, or none is. The Import
    /// Center card (lane US) calls this through `lungfish-cli import fastq <batch folder> --adopt`, whose argv is
    /// `cliArguments(resultFolder: batchFolder, ...)`. `progress` is called on the adopting task, in order.
    package static func adoptBatch(
        batchFolder: URL, projectDirectory: URL, force: Bool = false, eventsOn: Bool = false,
        progress: @Sendable (ExecutorBatchAdoptProgress) -> Void = { _ in }
    ) async throws(ExecutorBatchAdoptError) -> [URL] {
        try await adoptBatch(
            batchFolder: batchFolder, projectDirectory: projectDirectory, force: force, eventsOn: eventsOn, policy: .release,
            progress: progress
        )
    }

    static func adoptBatch(
        batchFolder: URL, projectDirectory: URL, force: Bool = false, eventsOn: Bool = false, policy: ExecutorAdoptPolicy,
        signingEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        progress: @Sendable (ExecutorBatchAdoptProgress) -> Void = { _ in }
    ) async throws(ExecutorBatchAdoptError) -> [URL] {
        // BADOPT M1: the stub the frozen ends fail against; M2 writes the batch.
        throw .notABatch("The batch adopt is not written yet. Nothing was imported.")
    }

    /// `--dry-run` of a batch: every preflight with nothing written, and the sample names the bundles would take.
    package static func dryRunBatch(
        batchFolder: URL, projectDirectory: URL, force: Bool = false
    ) throws(ExecutorBatchAdoptError) -> [String] {
        let samples = try sampleFolders(in: batchFolder)
        return try checkBatch(samples, projectDirectory: projectDirectory, force: force, policy: .release) { _ in }
            .map(\.run.sampleName)
    }

    /// D2 a (AR:13, SW:10): every preflight of every sample before the first write. `check` reads each folder's plan,
    /// record and payload once, `preflight` its inputs, platform, recipe, statistics, reports and the bundle the project
    /// holds already (D3, AR:14, BI:14), and two samples that would make one bundle are both refused. It writes nothing,
    /// and it throws every refusal at once, in the batch's order.
    static func checkBatch(
        _ samples: [ExecutorBatchSampleFolder], projectDirectory: URL, force: Bool, policy: ExecutorAdoptPolicy,
        progress: (ExecutorBatchAdoptProgress) -> Void
    ) throws(ExecutorBatchAdoptError) -> [ExecutorBatchCheckedSample] {
        var checked: [ExecutorBatchCheckedSample] = []
        var refusals: [ExecutorBatchAdoptRefusal] = []
        for (index, sample) in samples.enumerated() {
            if Task.isCancelled { throw .cancelled(adopted: [], notAdopted: samples.map(\.name), sampleCount: samples.count) }
            progress(.checking(sample: sample.name, index: index + 1, count: samples.count))
            do {
                let run = try check(sample.folder, policy: policy)
                let planned = try preflight(run, projectDirectory: projectDirectory, force: force)
                checked.append(ExecutorBatchCheckedSample(name: sample.name, run: run, bundle: planned.url))
            } catch let refusal as ExecutorAdoptRefusal {
                refusals.append(ExecutorBatchAdoptRefusal(sample: sample.name, field: refusal.field, cause: refusal.cause, gap: refusal.gap))
            } catch BatchImportError.outputBundleAlreadyExists(let url) {
                refusals.append(ExecutorBatchAdoptRefusal(
                    sample: sample.name, field: "sampleName", cause: "The project already holds the bundle \(url.lastPathComponent).",
                    gap: nil
                ))
            } catch {
                refusals.append(ExecutorBatchAdoptRefusal(sample: sample.name, field: "sample", cause: error.localizedDescription, gap: nil))
            }
        }
        // A case-blind key, since the Mac's file system takes `A` and `a` for one bundle.
        let byBundle = Dictionary(grouping: checked) { $0.bundle.standardizedFileURL.path.lowercased() }
        for sample in checked {
            let others = (byBundle[sample.bundle.standardizedFileURL.path.lowercased()] ?? []).filter { $0.name != sample.name }
            guard !others.isEmpty else { continue }
            refusals.append(ExecutorBatchAdoptRefusal(
                sample: sample.name, field: "sampleName",
                cause: "Another sample of the batch, \(others.map(\.name).joined(separator: ", ")), makes the same bundle "
                    + "\(sample.bundle.lastPathComponent).",
                gap: nil
            ))
        }
        guard refusals.isEmpty else {
            let order = Dictionary(samples.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = refusals.enumerated().sorted {
                (order[$0.element.sample] ?? 0, $0.offset) < (order[$1.element.sample] ?? 0, $1.offset)
            }
            throw .refused(sorted.map(\.element), sampleCount: samples.count)
        }
        return checked
    }
}
