// RiboDetectorStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Recipe step that removes ribosomal RNA from paired-end FASTQ reads using RiboDetector.
public struct RiboDetectorStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "ribodetector-filter"
    public static let displayName: String = "Ribosomal RNA Removal"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    // MARK: - Parameters

    public let retention: FASTQRiboDetectorRetention
    public let ensureMode: FASTQRiboDetectorEnsure
    public let readLength: Int?
    public let chunkSize: Int?

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        let retentionValue = params?["retain"]?.stringValue ?? FASTQRiboDetectorRetention.nonRRNA.rawValue
        guard let retention = FASTQRiboDetectorRetention(rawValue: retentionValue.lowercased()) else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "retain",
                value: retentionValue
            )
        }
        guard retention == .nonRRNA else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "retain",
                value: retentionValue
            )
        }
        self.retention = retention

        let ensureValue = params?["ensure"]?.stringValue ?? FASTQRiboDetectorEnsure.rrna.rawValue
        guard let ensureMode = FASTQRiboDetectorEnsure(rawValue: ensureValue.lowercased()) else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "ensure",
                value: ensureValue
            )
        }
        self.ensureMode = ensureMode

        if let readLength = params?["readLength"]?.intValue {
            guard readLength > 0 else {
                throw RecipeEngineError.invalidParam(
                    step: Self.typeID,
                    param: "readLength",
                    value: "\(readLength)"
                )
            }
            self.readLength = readLength
        } else {
            self.readLength = nil
        }

        if let chunkSize = params?["chunkSize"]?.intValue {
            guard chunkSize > 0 else {
                throw RecipeEngineError.invalidParam(
                    step: Self.typeID,
                    param: "chunkSize",
                    value: "\(chunkSize)"
                )
            }
            self.chunkSize = chunkSize
        } else {
            self.chunkSize = nil
        }
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2,
                got: input.format,
                step: Self.typeID
            )
        }

        let effectiveReadLength: Int
        if let readLength {
            effectiveReadLength = readLength
        } else {
            effectiveReadLength = try await inferMeanReadLength(from: input.r1)
        }
        let outR1 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_norrna_R1.fastq.gz"
        )
        let outR2 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_norrna_R2.fastq.gz"
        )

        var args = [
            "-t", "\(context.threads)",
            "-l", "\(effectiveReadLength)",
            "-i", input.r1.path, r2.path,
            "-e", ensureMode.rawValue,
            "-o", outR1.path, outR2.path,
        ]
        if let chunkSize {
            args += ["--chunk_size", "\(chunkSize)"]
        }

        let result = try await context.runner.run(
            .ribodetector,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .ribodetector, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "ribodetector_cpu",
                step: Self.typeID,
                stderr: result.stderr
            )
        }

        return StepOutput(
            r1: outR1,
            r2: outR2,
            format: .pairedR1R2,
            tool: .ribodetector,
            arguments: args
        )
    }

    private func inferMeanReadLength(from inputURL: URL, sampleLimit: Int = 1000) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var totalLength = 0
        var sampledCount = 0

        for try await record in reader.records(from: inputURL) {
            totalLength += record.sequence.count
            sampledCount += 1
            if sampledCount >= sampleLimit {
                break
            }
        }

        guard sampledCount > 0 else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "readLength",
                value: "empty input"
            )
        }
        return max(1, Int((Double(totalLength) / Double(sampledCount)).rounded()))
    }
}
