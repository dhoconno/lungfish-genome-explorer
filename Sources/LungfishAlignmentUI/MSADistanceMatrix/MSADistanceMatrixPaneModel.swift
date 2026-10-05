// MSADistanceMatrixPaneModel.swift - Options, status and off-main computation for the Distances pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension MSADistanceMatrix: MSADistanceMatrixDisplaying {
    public var displayNames: [String] { names }
    public var displayRecordIndices: [Int] { recordIndices }
    public var displayValues: [[Double]] { values }
    public func displayComparableSites(row: Int, column: Int) -> Int {
        detail(row: row, column: column).comparableSites
    }
    public var squareTSV: String { tsv }
}

/// Holds the pane's options, loads the alignment and computes the matrix
/// off the main actor with the same LungfishIO code the CLI runs.
///
/// A generation counter guards every publish, so a slow result for old
/// options never replaces a newer one.
@MainActor
public final class MSADistanceMatrixPaneModel {
    public enum Status: Equatable {
        case idle
        case computing
        case tooManyRows(Int)
        case failed(String)
        case ready
    }

    public typealias Compute = @Sendable ([MSAAlignedRecord], MSADistanceOptions) async throws -> MSADistanceMatrix
    public typealias RecordLoader = @Sendable (URL) async throws -> [MSAAlignedRecord]

    /// UserDefaults keys. Options persist globally, not per bundle (ruling U10).
    public enum DefaultsKey {
        public static let model = "msaDistanceMatrix.model"
        public static let gaps = "msaDistanceMatrix.gaps"
        public static let order = "msaDistanceMatrix.order"
        public static let fixedUnitRange = "msaDistanceMatrix.fixedUnitRange"
        public static let showsValues = "msaDistanceMatrix.showsValues"
    }

    public private(set) var status: Status = .idle { didSet { onChange?() } }
    public private(set) var matrix: MSADistanceMatrix?
    public private(set) var records: [MSAAlignedRecord] = []
    public private(set) var alphabet: MSASequenceAlphabet = .nucleotide
    public private(set) var generation = 0
    /// Results that arrived for superseded options and were dropped.
    public private(set) var droppedResultCount = 0

    public var maxRowsForInlineMatrix = 200

    /// Called after every status or option change.
    public var onChange: (() -> Void)?

    public var model: MSADistanceModel {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model.rawValue, forKey: DefaultsKey.model)
            recompute()
        }
    }

    public var gaps: MSAGapPolicy {
        didSet {
            guard gaps != oldValue else { return }
            defaults.set(gaps.rawValue, forKey: DefaultsKey.gaps)
            recompute()
        }
    }

    public var order: MSADistanceOrder {
        didSet {
            guard order != oldValue else { return }
            defaults.set(order.rawValue, forKey: DefaultsKey.order)
            recompute()
        }
    }

    public var fixedUnitRange: Bool {
        didSet {
            defaults.set(fixedUnitRange, forKey: DefaultsKey.fixedUnitRange)
            onChange?()
        }
    }

    public var showsValues: Bool {
        didSet {
            defaults.set(showsValues, forKey: DefaultsKey.showsValues)
            onChange?()
        }
    }

    private let defaults: UserDefaults
    private let compute: Compute
    private let loadRecords: RecordLoader
    private var task: Task<Void, Never>?

    public init(
        defaults: UserDefaults = .standard,
        compute: @escaping Compute = MSADistanceMatrixPaneModel.computeOffMain,
        loadRecords: @escaping RecordLoader = MSADistanceMatrixPaneModel.loadRecordsOffMain
    ) {
        self.defaults = defaults
        self.compute = compute
        self.loadRecords = loadRecords
        model = defaults.string(forKey: DefaultsKey.model).flatMap(MSADistanceModel.init(rawValue:)) ?? .identity
        gaps = defaults.string(forKey: DefaultsKey.gaps).flatMap(MSAGapPolicy.init(rawValue:)) ?? .pairwise
        order = defaults.string(forKey: DefaultsKey.order).flatMap(MSADistanceOrder.init(rawValue:)) ?? .alignment
        fixedUnitRange = defaults.object(forKey: DefaultsKey.fixedUnitRange) as? Bool ?? false
        showsValues = defaults.object(forKey: DefaultsKey.showsValues) as? Bool ?? true
    }

    // MARK: Derived

    /// The options the matrix on screen, Copy Matrix and Export use.
    public var options: MSADistanceOptions {
        MSADistanceOptions(model: effectiveModel, gaps: gaps, order: order, alphabet: alphabet)
    }

    /// Models valid for the bundle alphabet, the only ones the popup lists.
    public var availableModels: [MSADistanceModel] { MSADistanceModel.models(for: alphabet) }

    /// A stored model the alphabet does not allow falls back to identity.
    public var effectiveModel: MSADistanceModel {
        availableModels.contains(model) ? model : .identity
    }

    /// Fixed 0-1 applies to identity and p-distance only (ruling P8).
    public var isFixedUnitRangeAvailable: Bool { !effectiveModel.isCorrectedDistance }

    public var usesFixedUnitRange: Bool { fixedUnitRange && isFixedUnitRangeAvailable }

    public var colorScale: MSADistanceColorScale {
        MSADistanceColorScale(values: matrix?.values ?? [], fixedUnitRange: usesFixedUnitRange)
    }

    /// Export stays possible when the inline matrix is too large.
    public var canExport: Bool { !records.isEmpty }

    // MARK: Loading

    /// Loads the bundle's primary alignment off the main actor, then computes.
    public func load(bundleURL: URL, alphabet: MSASequenceAlphabet) {
        generation += 1
        let expected = generation
        self.alphabet = alphabet
        records = []
        matrix = nil
        status = .computing
        task?.cancel()
        let loader = loadRecords
        task = Task { [weak self] in
            do {
                let loaded = try await loader(bundleURL)
                guard let self, self.generation == expected else { return }
                self.load(records: loaded, alphabet: alphabet)
            } catch {
                guard let self, self.generation == expected else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Uses records the caller already parsed.
    public func load(records: [MSAAlignedRecord], alphabet: MSASequenceAlphabet) {
        self.alphabet = alphabet
        self.records = records
        recompute()
    }

    /// Recomputes for the current options. Any result still in flight for
    /// older options is dropped when it arrives.
    public func recompute() {
        generation += 1
        let expected = generation
        task?.cancel()
        matrix = nil
        guard !records.isEmpty else {
            status = .idle
            return
        }
        if records.count > maxRowsForInlineMatrix {
            status = .tooManyRows(records.count)
            return
        }
        status = .computing
        let records = self.records
        let options = self.options
        let compute = self.compute
        task = Task { [weak self] in
            do {
                let result = try await compute(records, options)
                guard let self else { return }
                guard self.generation == expected else {
                    self.droppedResultCount += 1
                    return
                }
                self.matrix = result
                self.status = .ready
            } catch {
                guard let self else { return }
                guard self.generation == expected else {
                    self.droppedResultCount += 1
                    return
                }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Defaults

    public nonisolated static let computeOffMain: Compute = { records, options in
        try await Task.detached(priority: .userInitiated) {
            try MSADistanceMatrix(records: records, options: options)
        }.value
    }

    public nonisolated static let loadRecordsOffMain: RecordLoader = { url in
        try await Task.detached(priority: .userInitiated) {
            try MSAAlignedRecord.loadPrimaryAlignment(of: url)
        }.value
    }
}
