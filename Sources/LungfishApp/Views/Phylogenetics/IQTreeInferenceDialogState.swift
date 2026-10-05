// IQTreeInferenceDialogState.swift - State and readiness rules of the IQ-TREE sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Observation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the dialog needs to know about the input alignment. It is read from the
/// bundle's manifest and row metadata, so the dialog never loads residues.
struct IQTreeAlignmentSummary: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let id: String
        let displayName: String
    }

    let rows: [Row]
    let alignedLength: Int
    /// The bundle alphabet: "dna", "rna", "protein" or "unknown".
    let alphabet: String

    var isNucleotide: Bool {
        let value = alphabet.lowercased()
        return value == "dna" || value == "rna"
    }

    var isProtein: Bool {
        alphabet.lowercased() == "protein"
    }

    static func load(bundleURL: URL) -> IQTreeAlignmentSummary? {
        guard let bundle = try? MultipleSequenceAlignmentBundle.load(from: bundleURL) else { return nil }
        return IQTreeAlignmentSummary(
            rows: bundle.rows
                .sorted { $0.order < $1.order }
                .map { Row(id: $0.id, displayName: $0.displayName) },
            alignedLength: bundle.manifest.alignedLength,
            alphabet: bundle.manifest.alphabet
        )
    }
}

/// The "Build from" choice (K4).
enum IQTreeBuildScope: String, CaseIterable, Sendable {
    case whole
    case selected
}

/// Sequence types the GUI offers (D3). BIN, MORPH and NT2AA stay in the CLI.
enum IQTreeSequenceTypeOption: String, CaseIterable, Sendable {
    case auto
    case dna
    case codon
    case protein

    var displayName: String {
        switch self {
        case .auto: return "Detect automatically"
        case .dna: return "DNA"
        case .codon: return "Codon"
        case .protein: return "Protein"
        }
    }
}

/// Genetic codes offered with the Codon sequence type (D3).
enum IQTreeGeneticCode: String, CaseIterable, Sendable {
    case standard = "CODON1"
    case vertebrateMitochondrial = "CODON2"

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .vertebrateMitochondrial: return "Vertebrate mitochondrial"
        }
    }
}

/// The Model pop-up (D2).
enum IQTreeModelChoice: Hashable, Sendable {
    case modelFinder
    case fixed(String)
    case custom

    var title: String {
        switch self {
        case .modelFinder: return "Find best model (ModelFinder)"
        case .fixed(let model): return model
        case .custom: return "Custom…"
        }
    }

    static let nucleotideModels = ["JC", "HKY+F+G4", "GTR+F+I+G4", "GTR+F+R4"]
    static let proteinModels = ["LG+G4", "WAG+G4", "JTT+G4", "LG+F+R4"]
}

@MainActor
@Observable
final class IQTreeInferenceDialogState {
    static let toolID = "iqtree"
    static let warningSymbol = "\u{26A0}\u{FE0E}"
    static let seedPlaceholder = "Random"

    /// IQ-TREE's own minimum for `-B` (ultrafast bootstrap).
    static let ufbootStep = 1000
    static let ufbootRange = 1000...1_000_000
    static let alrtStep = 1000
    static let alrtRange = 1...1_000_000

    // Captions from rulings D4 to D7 and the phylo memo.
    static let branchSupportCaption = "UFBoot 95 or higher and SH-aLRT 80 or higher indicate a well-supported clade."
    static let ufbootMinimumCaption = "IQ-TREE requires at least 1000."
    static let seedCaption = "A random seed is drawn and recorded in the command."
    static let threadsCaption = "The same seed and thread count reproduce the same tree."
    static let outgroupCaption = "The outgroup sets where the tree is rooted. It does not change the inferred relationships."
    static let outgroupCommaCaption = "Names that contain a comma cannot be used as an outgroup and are not listed."
    static let safeModeCaption = "Slower. Use it if IQ-TREE reports numerical underflow."
    static let keepIdenticalCaption = "When off, IQ-TREE drops third and later identical copies from the search and adds them back as zero-length tips."
    static let advancedParametersCaption = "Advanced parameters are passed directly to IQ-TREE after the curated options."

    let request: MultipleSequenceAlignmentTreeInferenceRequest
    let projectURL: URL
    let alignment: IQTreeAlignmentSummary?
    let sidebarItems: [DatasetOperationToolSidebarItem]
    private let performanceCoreCount: Int

    var selectedToolID: String
    var scope: IQTreeBuildScope {
        didSet { applyScopeRules() }
    }
    var outputName: String
    var modelChoice: IQTreeModelChoice
    var customModel: String
    var sequenceType: IQTreeSequenceTypeOption
    var geneticCode: IQTreeGeneticCode
    var bootstrapEnabled: Bool
    var bootstrapReplicatesText: String
    var alrtEnabled: Bool
    var alrtReplicatesText: String
    var seedText: String
    var threadsText: String
    private(set) var selectedOutgroupNames: Set<String>
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var advancedOptionsExpanded: Bool
    var iqtreePath: String
    var extraIQTreeOptions: String
    var pendingOptions: IQTreeInferenceOptions?

    /// The thread default last written into `threadsText`. A scope change
    /// rewrites the field only while it still holds this value.
    private var appliedDefaultThreads: String

    convenience init(
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL
    ) {
        self.init(
            request: request,
            projectURL: projectURL,
            alignment: IQTreeAlignmentSummary.load(bundleURL: request.bundleURL),
            performanceCoreCount: Self.systemPerformanceCoreCount()
        )
    }

    init(
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL,
        alignment: IQTreeAlignmentSummary?,
        performanceCoreCount: Int,
        sidebarItems: [DatasetOperationToolSidebarItem] = [
            DatasetOperationToolSidebarItem(
                id: IQTreeInferenceDialogState.toolID,
                title: "Build Tree with IQ-TREE",
                subtitle: "Infer a maximum-likelihood tree from an alignment.",
                availability: .available
            )
        ]
    ) {
        self.request = request
        self.projectURL = projectURL
        self.alignment = alignment
        self.performanceCoreCount = max(1, performanceCoreCount)
        self.sidebarItems = sidebarItems
        self.selectedToolID = Self.toolID
        let requestRowCount = Self.selectorTokens(request.rows).count
        self.scope = requestRowCount >= 3 ? .selected : .whole
        self.outputName = Self.normalizedOutputName(request.suggestedName)
        self.modelChoice = .modelFinder
        self.customModel = ""
        self.sequenceType = .auto
        self.geneticCode = .standard
        self.bootstrapEnabled = true
        self.bootstrapReplicatesText = "1000"
        self.alrtEnabled = true
        self.alrtReplicatesText = "1000"
        self.seedText = ""
        self.threadsText = ""
        self.selectedOutgroupNames = []
        self.safeMode = false
        self.keepIdenticalSequences = false
        self.advancedOptionsExpanded = AppUITestConfiguration.current.isEnabled
        self.iqtreePath = ""
        self.extraIQTreeOptions = ""
        self.pendingOptions = nil
        self.appliedDefaultThreads = ""
        applyScopeRules()
    }

    // MARK: - Chrome

    var dialogTitle: String { "Build Tree with IQ-TREE" }
    var dialogSubtitle: String { "Infer a maximum-likelihood tree from an alignment." }
    var primaryActionTitle: String { "Build Tree" }
    var datasetLabel: String { request.displayName }

    var inputSummary: String {
        FASTQOperationDialogState.displayPath(for: request.bundleURL, relativeTo: projectURL)
    }

    var readinessText: String {
        if let validationMessage {
            return "\(Self.warningSymbol) \(validationMessage)"
        }
        return "Ready to build a tree."
    }

    var isRunEnabled: Bool { validationMessage == nil }

    // MARK: - Scope (K4)

    /// The Selected choice exists only when the request carries rows or columns.
    var offersSelectedScope: Bool {
        Self.selectorTokens(request.rows).isEmpty == false
            || Self.selectorTokens(request.columns).isEmpty == false
    }

    var wholeScopeTitle: String {
        guard let alignment else { return "Whole alignment" }
        return "Whole alignment (\(Self.sequenceCountText(alignment.rows.count)), \(alignment.alignedLength) columns)"
    }

    var selectedScopeTitle: String {
        let columnsText: String
        if let columns = request.columns?.trimmingCharacters(in: .whitespacesAndNewlines), columns.isEmpty == false {
            columnsText = "columns \(columns)"
        } else if let alignment {
            columnsText = "columns 1-\(alignment.alignedLength)"
        } else {
            columnsText = "all columns"
        }
        return "Selected rows and columns (\(Self.sequenceCountText(selectedRows.count)), \(columnsText))"
    }

    private var selectedRows: [IQTreeAlignmentSummary.Row] {
        guard let alignment else { return [] }
        let tokens = Self.selectorTokens(request.rows)
        guard tokens.isEmpty == false else { return alignment.rows }
        var matchedIDs = Set<String>()
        for token in tokens {
            if let row = alignment.rows.first(where: { $0.id == token })
                ?? alignment.rows.first(where: { $0.displayName == token }) {
                matchedIDs.insert(row.id)
            }
        }
        return alignment.rows.filter { matchedIDs.contains($0.id) }
    }

    private var hasUnresolvedSelectedRows: Bool {
        guard alignment != nil else { return false }
        return Set(Self.selectorTokens(request.rows)).count > selectedRows.count
    }

    var inScopeRows: [IQTreeAlignmentSummary.Row] {
        guard let alignment else { return [] }
        return effectiveScope == .selected ? selectedRows : alignment.rows
    }

    var inScopeSequenceCount: Int { inScopeRows.count }

    /// Nil when the selected column text cannot be read.
    var inScopeColumnCount: Int? {
        guard let alignment else { return nil }
        guard effectiveScope == .selected, Self.selectorTokens(request.columns).isEmpty == false else {
            return alignment.alignedLength
        }
        return Self.columnCount(request.columns ?? "", alignedLength: alignment.alignedLength)
    }

    private var effectiveScope: IQTreeBuildScope {
        offersSelectedScope ? scope : .whole
    }

    var isBranchSupportAvailable: Bool { inScopeSequenceCount >= 4 }

    var branchSupportUnavailableCaption: String? {
        isBranchSupportAvailable ? nil : "Bootstrap and SH-aLRT need at least 4 sequences."
    }

    // MARK: - Model and sequence type (D2, D3)

    var availableSequenceTypes: [IQTreeSequenceTypeOption] {
        guard let alignment else { return IQTreeSequenceTypeOption.allCases }
        if alignment.isNucleotide { return [.auto, .dna, .codon] }
        if alignment.isProtein { return [.auto, .protein] }
        return IQTreeSequenceTypeOption.allCases
    }

    var availableFixedModels: [String] {
        switch sequenceType {
        case .codon:
            return []
        case .dna:
            return IQTreeModelChoice.nucleotideModels
        case .protein:
            return IQTreeModelChoice.proteinModels
        case .auto:
            if alignment?.isNucleotide == true { return IQTreeModelChoice.nucleotideModels }
            if alignment?.isProtein == true { return IQTreeModelChoice.proteinModels }
            return IQTreeModelChoice.nucleotideModels + IQTreeModelChoice.proteinModels
        }
    }

    var modelChoices: [IQTreeModelChoice] {
        var choices: [IQTreeModelChoice] = [.modelFinder]
        choices += availableFixedModels.map { IQTreeModelChoice.fixed($0) }
        if case .fixed(let model) = modelChoice, availableFixedModels.contains(model) == false {
            // Keep the current pick listed so the pop-up never shows a blank
            // selection. Readiness explains why it cannot run.
            choices.append(modelChoice)
        }
        choices.append(.custom)
        return choices
    }

    private var effectiveModel: String {
        switch modelChoice {
        case .modelFinder: return "MFP"
        case .fixed(let model): return model
        case .custom: return customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var sequenceTypeArgument: String {
        switch sequenceType {
        case .auto: return "auto"
        case .dna: return "DNA"
        case .codon: return geneticCode.rawValue
        case .protein: return "AA"
        }
    }

    /// MF, TESTONLY and any preset ending in ONLY select a model and build no
    /// tree, so they are rejected in the Custom field (D2).
    /// The base is the part before the first "+", as the CLI reads it (C5).
    static func isModelSelectionOnly(_ model: String) -> Bool {
        let base = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "+", maxSplits: 1)
            .first
            .map { $0.uppercased() } ?? ""
        return base == "MF" || base.hasSuffix("ONLY")
    }

    /// IQ-TREE flags a curated control already sets, mapped to that control's
    /// dialog name. The CLI rejects them in the extra arguments (C6).
    static let reservedAdvancedFlags: [String: String] = [
        "-s": "the alignment",
        "--prefix": "Output name",
        "-pre": "Output name",
        "-m": "Model",
        "-T": "Threads",
        "-nt": "Threads",
        "--seed": "Seed",
        "-seed": "Seed",
        "-B": "UFBoot",
        "-bb": "UFBoot",
        "--ufboot": "UFBoot",
        "--alrt": "SH-aLRT",
        "-alrt": "SH-aLRT",
        "-o": "Outgroup",
        "-st": "Sequence type",
        "--seqtype": "Sequence type",
    ]

    // MARK: - Branch support steppers

    var bootstrapReplicatesStepperValue: Int {
        get { Self.clamped(Int(bootstrapReplicatesText.trimmingCharacters(in: .whitespaces)), to: Self.ufbootRange) }
        set { bootstrapReplicatesText = String(Self.clamped(newValue, to: Self.ufbootRange)) }
    }

    var alrtReplicatesStepperValue: Int {
        get { Self.clamped(Int(alrtReplicatesText.trimmingCharacters(in: .whitespaces)), to: Self.alrtRange) }
        set { alrtReplicatesText = String(Self.clamped(newValue, to: Self.alrtRange)) }
    }

    // MARK: - Outgroup (D7)

    var outgroupCandidates: [String] {
        var seen = Set<String>()
        return inScopeRows
            .map(\.displayName)
            .filter { $0.contains(",") == false && seen.insert($0).inserted }
    }

    var hasCommaNamesExcludedFromOutgroup: Bool {
        inScopeRows.contains { $0.displayName.contains(",") }
    }

    func isOutgroupSelected(_ name: String) -> Bool {
        selectedOutgroupNames.contains(name)
    }

    func setOutgroup(_ name: String, selected: Bool) {
        guard outgroupCandidates.contains(name) else { return }
        if selected {
            selectedOutgroupNames.insert(name)
        } else {
            selectedOutgroupNames.remove(name)
        }
    }

    private var orderedOutgroup: [String] {
        outgroupCandidates.filter { selectedOutgroupNames.contains($0) }
    }

    // MARK: - Threads (D6)

    /// 1 thread when the scope has fewer than 50 sequences and fewer than
    /// 10,000 columns, otherwise the performance core count capped at 8.
    var defaultThreadCount: Int {
        let columns = inScopeColumnCount ?? 0
        if inScopeSequenceCount < 50 && columns < 10_000 { return 1 }
        return min(performanceCoreCount, 8)
    }

    static func systemPerformanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - Readiness

    var validationMessage: String? {
        guard alignment != nil else {
            return "The alignment bundle could not be read."
        }
        if outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an output name."
        }
        if effectiveScope == .selected && hasUnresolvedSelectedRows {
            return "The selection names rows that are not in the alignment."
        }
        if inScopeSequenceCount < 3 {
            return "IQ-TREE needs at least 3 sequences. This scope has \(inScopeSequenceCount)."
        }
        guard let columnCount = inScopeColumnCount, columnCount > 0 else {
            return "The selected columns could not be read."
        }
        if let message = modelValidationMessage {
            return message
        }
        if sequenceType == .codon && columnCount % 3 != 0 {
            return "Codon models need a column count that is a multiple of 3. This scope has \(columnCount) columns."
        }
        if isBranchSupportAvailable && bootstrapEnabled {
            guard let value = Self.wholeNumber(bootstrapReplicatesText) else {
                return "UFBoot replicates must be a whole number."
            }
            if value < Self.ufbootRange.lowerBound {
                return "UFBoot replicates must be at least \(Self.ufbootRange.lowerBound)."
            }
        }
        if isBranchSupportAvailable && alrtEnabled {
            guard let value = Self.wholeNumber(alrtReplicatesText) else {
                return "SH-aLRT replicates must be a whole number."
            }
            if value < Self.alrtRange.lowerBound {
                return "SH-aLRT replicates must be at least \(Self.alrtRange.lowerBound)."
            }
        }
        if seedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guard let seed = Self.wholeNumber(seedText), seed >= 1, seed <= Int(Int32.max) else {
                return "Seed must be a whole number."
            }
        }
        guard let threads = Self.wholeNumber(threadsText), threads >= 1 else {
            return "Threads must be a whole number."
        }
        let advanced: [String]
        do {
            advanced = try AdvancedCommandLineOptions.parse(extraIQTreeOptions)
        } catch {
            return error.localizedDescription
        }
        for argument in advanced {
            let flag = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if let control = Self.reservedAdvancedFlags[flag] {
                return "Remove \(flag) from the additional parameters. Use \(control) instead."
            }
        }
        return nil
    }

    private var modelValidationMessage: String? {
        switch modelChoice {
        case .modelFinder:
            return nil
        case .fixed(let model):
            guard availableFixedModels.contains(model) else {
                if sequenceType == .codon {
                    return "\(model) is not a codon model. Choose Find best model (ModelFinder) or a custom codon model."
                }
                return "\(model) does not fit this sequence type. Choose another model."
            }
            return nil
        case .custom:
            let model = effectiveModel
            if model.isEmpty {
                return "Enter a custom IQ-TREE model."
            }
            if Self.isModelSelectionOnly(model) {
                return "\(model) only selects a model and builds no tree. Choose Find best model (ModelFinder) instead."
            }
            return nil
        }
    }

    // MARK: - Run

    func selectTool(named rawValue: String) {
        guard rawValue == Self.toolID else { return }
        selectedToolID = rawValue
    }

    func prepareForRun() {
        guard isRunEnabled, let threads = Self.wholeNumber(threadsText) else {
            pendingOptions = nil
            return
        }
        let isSelected = effectiveScope == .selected
        let supportAvailable = isBranchSupportAvailable
        pendingOptions = IQTreeInferenceOptions(
            outputName: Self.normalizedOutputName(outputName),
            rows: isSelected ? trimmedOptional(request.rows ?? "") : nil,
            columns: isSelected ? trimmedOptional(request.columns ?? "") : nil,
            model: effectiveModel,
            sequenceType: sequenceTypeArgument,
            bootstrap: supportAvailable && bootstrapEnabled ? Self.wholeNumber(bootstrapReplicatesText) : nil,
            alrt: supportAvailable && alrtEnabled ? Self.wholeNumber(alrtReplicatesText) : nil,
            seed: Self.wholeNumber(seedText),
            threads: threads,
            outgroup: orderedOutgroup,
            safeMode: safeMode,
            keepIdenticalSequences: keepIdenticalSequences,
            iqtreePath: trimmedOptional(iqtreePath),
            extraIQTreeOptions: extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Scope rules

    private func applyScopeRules() {
        if isBranchSupportAvailable == false {
            bootstrapEnabled = false
            alrtEnabled = false
        }
        let candidates = Set(outgroupCandidates)
        let kept = selectedOutgroupNames.intersection(candidates)
        if kept != selectedOutgroupNames {
            selectedOutgroupNames = kept
        }
        let newDefault = String(defaultThreadCount)
        if threadsText == appliedDefaultThreads {
            threadsText = newDefault
        }
        appliedDefaultThreads = newDefault
    }

    // MARK: - Helpers

    private func trimmedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A whole number written with digits only. "1e3", "1.5" and "-5" are not.
    static func wholeNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(trimmed)
    }

    private static func clamped(_ value: Int?, to range: ClosedRange<Int>) -> Int {
        guard let value else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func selectorTokens(_ text: String?) -> [String] {
        (text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    /// Counts the distinct 1-based columns named by "10-40,55". Nil when a
    /// part cannot be read or falls outside the alignment.
    static func columnCount(_ text: String, alignedLength: Int) -> Int? {
        var columns = IndexSet()
        for token in selectorTokens(text) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int
            let upper: Int
            switch bounds.count {
            case 1:
                guard let value = wholeNumber(bounds[0]) else { return nil }
                lower = value
                upper = value
            case 2:
                guard let start = wholeNumber(bounds[0]), let end = wholeNumber(bounds[1]) else { return nil }
                lower = start
                upper = end
            default:
                return nil
            }
            guard lower >= 1, upper >= lower, upper <= alignedLength else { return nil }
            columns.insert(integersIn: lower...upper)
        }
        return columns.count
    }

    private static func sequenceCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "sequence" : "sequences")"
    }

    private static func normalizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "iqtree-analysis" : trimmed
        return name.hasSuffix(".lungfishtree")
            ? String(name.dropLast(".lungfishtree".count))
            : name
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
