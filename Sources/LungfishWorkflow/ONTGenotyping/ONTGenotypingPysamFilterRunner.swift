// ONTGenotypingPysamFilterRunner.swift - Runs the pysam-based ONT genotyping filter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SIMP-16 (2026-09-23 best-practices audit): the pysam filter script used to
// live as a ~190-line raw string literal in this file. It is unchanged
// (byte-identical) and now lives at Resources/ONTGenotyping/pysam-filter.py,
// loaded once via Bundle.module.

import Foundation

public struct ProcessONTGenotypingPysamFilterRunner: ONTGenotypingPysamFiltering {
    private let condaManager: CondaManager
    private let timeout: TimeInterval

    public init(
        condaManager: CondaManager = .shared,
        timeout: TimeInterval = 86_400
    ) {
        self.condaManager = condaManager
        self.timeout = timeout
    }

    public func filter(_ request: ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult {
        try Self.writeScript(to: request.scriptURL)
        try FileManager.default.createDirectory(
            at: request.outputBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: "python",
            arguments: request.pythonArguments,
            environment: "pysam",
            workingDirectory: request.outputBAMURL.deletingLastPathComponent(),
            timeout: timeout
        )
        let completedAt = Date()

        if result.exitCode != 0 {
            return ONTGenotypingFilterResult(
                inputBAMURL: request.inputBAMURL,
                outputBAMURL: request.outputBAMURL,
                outputBAIURL: request.outputBAIURL,
                totalAlignments: 0,
                passedAlignments: 0,
                genotypeCounts: [],
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                wallClockSeconds: completedAt.timeIntervalSince(startedAt)
            )
        }

        let payload = try JSONDecoder().decode(PysamFilterPayload.self, from: Data(result.stdout.utf8))
        return ONTGenotypingFilterResult(
            inputBAMURL: request.inputBAMURL,
            outputBAMURL: URL(fileURLWithPath: payload.outputBAM),
            outputBAIURL: URL(fileURLWithPath: payload.outputBAI),
            totalAlignments: payload.totalAlignments,
            passedAlignments: payload.passedAlignments,
            genotypeCounts: payload.genotypeCounts.map {
                ONTGenotypingGenotypeCount(
                    genotype: $0.genotype,
                    filteredIndelOnlyMappedReads: $0.filteredIndelOnlyMappedReads
                )
            },
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            wallClockSeconds: completedAt.timeIntervalSince(startedAt)
        )
    }

    public static func writeScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct PysamFilterPayload: Decodable {
    struct Count: Decodable {
        let genotype: String
        let filteredIndelOnlyMappedReads: Int
    }

    let sampleName: String
    let inputBAM: String
    let outputBAM: String
    let outputBAI: String
    let totalAlignments: Int
    let passedAlignments: Int
    let genotypeCounts: [Count]
}

private let filterScript: String = {
    guard let url = Bundle.module.url(
        forResource: "pysam-filter",
        withExtension: "py",
        subdirectory: "ONTGenotyping"
    ), let script = try? String(contentsOf: url, encoding: .utf8) else {
        preconditionFailure("Missing bundled resource ONTGenotyping/pysam-filter.py")
    }
    return script
}()
