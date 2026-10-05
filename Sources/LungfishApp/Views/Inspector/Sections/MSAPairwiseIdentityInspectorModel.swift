// MSAPairwiseIdentityInspectorModel.swift - State for the MSA Inspector's pairwise identity table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import Observation

/// Drives the "Pairwise Identity" section of the MSA Inspector.
///
/// The matrix is computed in-process by `MSADistanceMatrix`, the same implementation
/// `lungfish-cli msa distance` uses, so the table shows exactly the values the CLI writes.
/// "Copy TSV" hands over that TSV verbatim; "Export TSV…" is routed by the Inspector through
/// the CLI (Operation Center, provenance sidecar) via `onExportRequested`.
@Observable
@MainActor
final class MSAPairwiseIdentityInspectorModel {
    enum Status: Equatable {
        case idle
        case computing
        case ready
        case tooManyRows(Int)
        case failed(String)
    }

    /// Above this many rows the in-process table is skipped and the user is pointed at the
    /// exported TSV, which runs the same computation as a cancellable Operation Center job.
    nonisolated static let maxRowsForInlineTable = 200

    let bundleURL: URL
    private(set) var status: Status = .idle
    private(set) var matrix: MSADistanceMatrix?
    private(set) var pairs: [MSADistanceMatrix.Pair] = []
    var sortOrder: [KeyPathComparator<MSADistanceMatrix.Pair>] = [
        KeyPathComparator(\.sortableValue, order: .reverse),
    ]
    var model: MSADistanceModel = .identity {
        didSet {
            guard oldValue != model else { return }
            matrix = nil
            pairs = []
            if status == .ready { status = .idle }
        }
    }

    /// Set by the Inspector to run `msa distance` through the CLI and the Operation Center.
    var onExportRequested: ((MSAPairwiseIdentityInspectorModel) -> Void)?

    var pasteboard: PasteboardWriting = DefaultPasteboard()

    /// Loads the aligned FASTA; injected so tests can feed records without a bundle on disk.
    private let recordLoader: @Sendable (URL) throws -> [MSAAlignedRecord]

    init(
        bundleURL: URL,
        recordLoader: @escaping @Sendable (URL) throws -> [MSAAlignedRecord] = MSAAlignedRecord.loadPrimaryAlignment(of:)
    ) {
        self.bundleURL = bundleURL
        self.recordLoader = recordLoader
    }

    var sortedPairs: [MSADistanceMatrix.Pair] {
        pairs.sorted(using: sortOrder)
    }

    var tsv: String? { matrix?.tsv }

    /// Computes (or recomputes) the matrix for the current model off the main actor.
    func compute() async {
        guard status != .computing else { return }
        status = .computing
        let loader = recordLoader
        let url = bundleURL
        let model = self.model
        let outcome: Result<MSADistanceMatrix, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let records = try loader(url)
                if records.count > Self.maxRowsForInlineTable {
                    throw TooManyRows(count: records.count)
                }
                // The alphabet the CLI reads from the manifest. Injected test loaders have no bundle.
                let alphabet = (try? MSASequenceAlphabet.load(fromBundle: url)) ?? .nucleotide
                return .success(try MSADistanceMatrix(
                    records: records,
                    options: MSADistanceOptions(model: model, alphabet: alphabet)
                ))
            } catch {
                return .failure(error)
            }
        }.value

        // The model may have been switched while computing; only publish a matching result.
        guard model == self.model else {
            status = .idle
            return
        }
        switch outcome {
        case .success(let matrix):
            self.matrix = matrix
            self.pairs = matrix.uniquePairs
            self.status = .ready
        case .failure(let error as TooManyRows):
            self.matrix = nil
            self.pairs = []
            self.status = .tooManyRows(error.count)
        case .failure(let error):
            self.matrix = nil
            self.pairs = []
            self.status = .failed(error.localizedDescription)
        }
    }

    /// Copies the full square matrix as TSV in the CLI's layout.
    @discardableResult
    func copyTSV() -> Bool {
        guard let tsv else { return false }
        pasteboard.setString(tsv)
        return true
    }

    func requestExport() {
        onExportRequested?(self)
    }

    private struct TooManyRows: Error {
        let count: Int
    }
}
