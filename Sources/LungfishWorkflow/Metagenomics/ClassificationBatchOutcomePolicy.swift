// ClassificationBatchOutcomePolicy.swift - Outcome rules and completion text shared by the app and the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// One stable row in the human-readable classification batch summary.
struct ClassificationBatchSummaryRow: Sendable, Equatable {
    let sampleId: String
    let status: String
    let profileState: String
    let requestedRank: String
    let resolvedRank: String
    let totalReads: String
    let classifiedReads: String
    let classifiedPercentage: String
    let speciesCount: String
    let dominantSpecies: String
    let message: String
}

/// Aggregate terminal-state decision for a classification batch.
struct ClassificationBatchOutcomeEvaluation: Sendable, Equatable {
    let completedCount: Int
    let degradedCount: Int
    let failedCount: Int
    let requiresWarningCompletion: Bool
    let warningMessage: String
}

/// User-facing and analysis-manifest metadata for one valid Kraken2 result.
struct ClassificationSingleOutcomeMetadata: Sendable, Equatable {
    let requiresWarningCompletion: Bool
    let completionDetail: String
    let analysisSummary: String
    let analysisParameters: [String: AnalysisParameterValue]
}

/// Pure formatting and terminal-state policy shared by app execution and tests.
enum ClassificationBatchOutcomePolicy {
    static let summaryHeader = "sample_id\tstatus\tprofile_state\trequested_rank\tresolved_rank\ttotal_reads\tclassified_reads\tclassified_pct\tspecies_count\tdominant_species\tmessage"

    static func row(sampleId: String, result: ClassificationResult) -> ClassificationBatchSummaryRow {
        let outcome = result.profileOutcome
        let resolution = outcome.resolution
        let requestedRank = resolution?.request.provenanceValue
            ?? result.config.brackenProfileRequest?.rank.provenanceValue
            ?? ""
        let resolvedRank = resolution.flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) } ?? ""
        let message = outcome.state == .degraded
            ? (outcome.message ?? outcome.reason?.rawValue ?? "Bracken profiling degraded")
            : ""
        return ClassificationBatchSummaryRow(
            sampleId: sampleId,
            status: outcome.state == .degraded ? "degraded" : "ok",
            profileState: outcome.state.rawValue,
            requestedRank: requestedRank,
            resolvedRank: resolvedRank,
            totalReads: String(result.tree.totalReads),
            classifiedReads: String(result.tree.classifiedReads),
            classifiedPercentage: String(format: "%.2f", result.tree.classifiedFraction * 100),
            speciesCount: String(result.tree.speciesCount),
            dominantSpecies: result.tree.dominantSpecies?.name ?? "",
            message: message
        )
    }

    static func failedRow(sampleId: String, message: String) -> ClassificationBatchSummaryRow {
        ClassificationBatchSummaryRow(
            sampleId: sampleId,
            status: "failed",
            profileState: "",
            requestedRank: "",
            resolvedRank: "",
            totalReads: "",
            classifiedReads: "",
            classifiedPercentage: "",
            speciesCount: "",
            dominantSpecies: "",
            message: message
        )
    }

    static func summaryTSV(rows: [ClassificationBatchSummaryRow]) -> String {
        let lines = rows.map { row in
            [
                row.sampleId,
                row.status,
                row.profileState,
                row.requestedRank,
                row.resolvedRank,
                row.totalReads,
                row.classifiedReads,
                row.classifiedPercentage,
                row.speciesCount,
                row.dominantSpecies,
                row.message,
            ]
            .map(appTSVField)
            .joined(separator: "\t")
        }
        return ([summaryHeader] + lines).joined(separator: "\n")
    }

    static func evaluate(
        rows: [ClassificationBatchSummaryRow],
        sqliteWarning: String?
    ) -> ClassificationBatchOutcomeEvaluation {
        let completedCount = rows.filter { $0.status == "ok" }.count
        let degradedCount = rows.filter { $0.status == "degraded" }.count
        let failedCount = rows.filter { $0.status == "failed" }.count
        var warnings: [String] = []
        if degradedCount > 0 {
            warnings.append("\(degradedCount) sample\(degradedCount == 1 ? "" : "s") retained Kraken2 classifications but Bracken profiling degraded")
        }
        if failedCount > 0 {
            warnings.append("\(failedCount) sample\(failedCount == 1 ? "" : "s") failed")
        }
        if let sqliteWarning, !sqliteWarning.isEmpty {
            warnings.append(sqliteWarning)
        }
        return ClassificationBatchOutcomeEvaluation(
            completedCount: completedCount,
            degradedCount: degradedCount,
            failedCount: failedCount,
            requiresWarningCompletion: !warnings.isEmpty,
            warningMessage: warnings.joined(separator: "; ")
        )
    }

    static func singleResultMetadata(
        for result: ClassificationResult
    ) -> ClassificationSingleOutcomeMetadata {
        let tree = result.tree
        let outcome = result.profileOutcome
        var parameters = result.config.summaryParameters()
        parameters["profileState"] = .string(outcome.state.rawValue)
        if let rank = outcome.resolution.flatMap({ BrackenDatabaseCapabilities.levelCode(for: $0.rank) }) {
            parameters["brackenResolvedRank"] = .string(rank)
        }
        if let reason = outcome.reason {
            parameters["brackenDegradationReason"] = .string(reason.rawValue)
        }
        if let message = outcome.message {
            parameters["brackenMessage"] = .string(message)
        }
        if let toolVersion = outcome.toolVersion {
            parameters["brackenToolVersion"] = .string(toolVersion)
        }

        let classificationDetail = "\(tree.classifiedReads) of \(tree.totalReads) reads classified"
        let analysisBase = "\(tree.totalReads) reads, \(tree.classifiedReads) classified"
        guard outcome.state == .degraded else {
            return ClassificationSingleOutcomeMetadata(
                requiresWarningCompletion: false,
                completionDetail: classificationDetail,
                analysisSummary: analysisBase,
                analysisParameters: parameters
            )
        }

        let reason = outcome.message ?? outcome.reason?.rawValue ?? "unknown reason"
        let resolvedRank = outcome.resolution
            .flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) }
            ?? "unknown"
        return ClassificationSingleOutcomeMetadata(
            requiresWarningCompletion: true,
            completionDetail: "\(classificationDetail); Bracken profiling degraded at resolved rank \(resolvedRank): \(reason)",
            analysisSummary: "\(analysisBase); profiling degraded at resolved rank \(resolvedRank): \(reason)",
            analysisParameters: parameters
        )
    }
}
