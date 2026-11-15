// SingleCellNotHost+Errors.swift - Why a not-host pass was refused, in words a person can act on (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum SingleCellNotHostError: Error, Equatable, LocalizedError, Sendable {
    case recordMissing(bam: String, record: String)
    case recordLength(bam: String, record: String, bamLength: Int, setLength: Int)
    case unreadableAlignment(String)
    case bamNotIndexed(String)
    case samtoolsFailed(bam: String, words: String)
    case noRawMatrix(sample: String, folder: String)
    case rawMatrixDiffers(sample: String, stated: Int, listed: Int)
    case geneNotInSet(gene: String, sample: String, set: String)
    case noBAMForSample(String)
    case bamOfNoSample(String, samples: [String])
    case malformedBAMOption(String)
    case cellsDiffer(String)
    case extraRecordUnreadable(extra: String, file: String)

    public var errorDescription: String? {
        switch self {
        case .recordMissing(let bam, let record):
            return "The BAM \(bam) holds no record \(record), which the reference set names as not host, so its reads were not aligned to this set. Give the BAM that STARsolo or Cell Ranger wrote against this set."
        case .recordLength(let bam, let record, let bamLength, let setLength):
            return "The BAM \(bam) holds \(record) at \(bamLength) bases and the reference set at \(setLength), so its reads were aligned to another sequence. Give the BAM that STARsolo or Cell Ranger wrote against this set."
        case .unreadableAlignment(let line):
            return "samtools printed a line LGE cannot read as an alignment (\(line)). Check the BAM with samtools quickcheck and import again."
        case .bamNotIndexed(let path):
            return "The BAM \(path) has no index (.bai or .csi) beside it. Index it with samtools index and import again."
        case .samtoolsFailed(let bam, let words):
            return "samtools could not read the BAM \(bam): \(words)"
        case .noRawMatrix(let sample, let folder):
            return "The folder \(folder) of \(sample) has no raw matrix (Solo.out/Gene/raw/ or outs/raw_feature_bc_matrix/), so its ambient pool cannot be counted. Import the folder as the tool wrote it."
        case .rawMatrixDiffers(let sample, let stated, let listed):
            return "The raw matrix of \(sample) states \(stated) barcodes in its size line and its barcodes.tsv lists \(listed), so the files do not belong together."
        case .geneNotInSet(let gene, let sample, let set):
            return "The feature \(gene) of \(sample) is not in the reference set \(set), so the folder was not counted on this set. Name the set the tool counted against."
        case .noBAMForSample(let sample):
            return "The reference set holds not-host sequences, so each sample needs its BAM. Pass --not-host-bam \(sample)=<path to its sorted, indexed BAM>."
        case .bamOfNoSample(let sample, let samples):
            return "--not-host-bam names the sample \(sample), and the samples are \(samples.joined(separator: ", "))."
        case .malformedBAMOption(let value):
            return "--not-host-bam takes <sample>=<path>, and \(value) holds no =."
        case .cellsDiffer(let sample):
            return "The cells of \(sample) differ between the not-host pass and its matrix, so the counts cannot be joined to them. Import the folder again."
        case .extraRecordUnreadable(let extra, let file):
            return "The reference set's file \(file) of the extra \(extra) could not be read, so its records' lengths are unknown. Check the set with lungfish-cli rnaseq reference-set."
        }
    }
}
