// ExecutorPlanNoPlanForm.swift - The steps and storage routes with no plan form in this build and the refusal each one meets (CHTC C5 lane SPLIT M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// A step or a storage route with no plan form in this build (`docs/formats/executor-plan.md`, "Steps"). Each case names
/// what the user can change.
package enum ExecutorPlanNoPlanForm: Error, Equatable, Sendable, LocalizedError {
    case riboDetector
    case interleavedToPaired
    case twoFilesWithNoBinning
    case gzipFileWithNoBinning
    case moreThanTwoFiles(count: Int)
    case recipeStep(stepType: String)
    case conversion(from: String, to: String)

    package var errorDescription: String? {
        switch self {
        case .riboDetector:
            return "This recipe removes ribosomal RNA with RiboDetector, which has no plan form in this build, so pass --no-remove-ribosomal-rna or import on this Mac without --write-plan."
        case .interleavedToPaired:
            return "This recipe splits interleaved reads into R1 and R2 files, which has no plan form in this build, so import the sample as R1 and R2 files or import on this Mac without --write-plan."
        case .twoFilesWithNoBinning:
            return "A plan cannot store two read files with no clumping and no quality binning in this build, so choose a --quality-binning scheme or a --clumping-tool, or import on this Mac without --write-plan."
        case .gzipFileWithNoBinning:
            return "A plan cannot keep one gzip file as it is with no clumping and no quality binning in this build, so choose a --quality-binning scheme or a --clumping-tool, or import on this Mac without --write-plan."
        case .moreThanTwoFiles(let count):
            return "A plan takes one or two read files a sample and this sample has \(count), so import its unpaired reads as a sample of their own or import on this Mac without --write-plan."
        case .recipeStep(let stepType):
            return "The recipe step \(stepType) has no plan form in this build, so choose another recipe or import on this Mac without --write-plan."
        case .conversion(let from, let to):
            return "The recipe's conversion from \(from) to \(to) has no plan form in this build, so choose another recipe or import on this Mac without --write-plan."
        }
    }

    /// The refusals a template request meets before planning: more than two files, and each recipe step or conversion
    /// with no plan form, named by its step type. A lone fastp trim or dedup step has one (C5 lane BF, D18).
    package static func check(_ request: ExecutorPlanTemplateRequest) throws {
        if request.inputSuffixes.count > 2 { throw moreThanTwoFiles(count: request.inputSuffixes.count) }
        guard let recipe = request.recipe else { return }
        for planned in try RecipeEngine().plan(recipe: recipe, inputFormat: request.inputFormat) {
            if case .singleStep(let executor, _) = planned, !(executor is any RecipePlannableStep) {
                let stepType = Swift.type(of: executor).typeID
                switch stepType {
                case "ribodetector-filter": throw riboDetector
                default: throw recipeStep(stepType: stepType)
                }
            }
            if case .formatConversion(let from, let to) = planned {
                switch (from, to) {
                case (.pairedR1R2, .interleaved), (.merged, .mixed): continue
                case (.interleaved, .pairedR1R2): throw interleavedToPaired
                default: throw conversion(from: from.rawValue, to: to.rawValue)
                }
            }
        }
    }

    /// The storage route `none` with no binning for two files or one gzip file, which the decoder refuses.
    package static func check(_ template: PlanTemplate, request: ExecutorPlanTemplateRequest) throws {
        guard request.storage.requestedClumpingTool == .none, request.storage.qualityBinning == .none,
              let storage = template.steps.first(where: { $0.kind == .storage }) else { return }
        if storage.inputs.count == 2 { throw twoFilesWithNoBinning }
        if storage.inputs.count == 1, storage.inputs[0].hasSuffix(".gz") { throw gzipFileWithNoBinning }
    }
}
