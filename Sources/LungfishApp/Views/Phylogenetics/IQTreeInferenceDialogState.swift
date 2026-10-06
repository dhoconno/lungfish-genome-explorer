// IQTreeInferenceDialogState.swift - State and readiness rules of the IQ-TREE sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
    static let threadsCaption = "One thread gives the same tree on every run. More threads can be faster on large alignments, but IQ-TREE then gives slightly different branch lengths each run."
    static let outgroupCaption = "The outgroup sets where the tree is rooted. It does not change the inferred relationships."
    static let safeModeCaption = "Slower. Use it if IQ-TREE reports numerical underflow."
    static let keepIdenticalCaption = "When off, IQ-TREE drops third and later identical copies from the search and adds them back as zero-length tips."
    static let advancedParametersCaption = "Advanced parameters are passed directly to IQ-TREE after the curated options."
    static let unorderedSupportCaptionText = "With -b or --lbp, LGE cannot tell which support value is which, so the tree records no support labels."

    let request: MultipleSequenceAlignmentTreeInferenceRequest
    let projectURL: URL
    let alignment: IQTreeAlignmentSummary?
    let sidebarItems: [DatasetOperationToolSidebarItem]

    var selectedToolID: String
    var scope: IQTreeBuildScope {
        didSet { applyScopeRules() }
    }
    var outputName: String
    var modelChoice: IQTreeModelChoice
    var customModel: String
    var sequenceType: IQTreeSequenceTypeOption
    var geneticCode: IQTreeGeneticCode
    var bootstrapEnabled: Bool {
        didSet { noteSupportBoxChange() }
    }
    var bootstrapReplicatesText: String
    var alrtEnabled: Bool {
        didSet { noteSupportBoxChange() }
    }
    var alrtReplicatesText: String
    var seedText: String
    var threadsText: String
    /// Row IDs, so names with commas or shared names never reach the CLI (m6).
    private(set) var selectedOutgroupRowIDs: Set<String>
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var advancedOptionsExpanded: Bool
    var iqtreePath: String
    var extraIQTreeOptions: String
    var pendingOptions: IQTreeInferenceOptions?

    /// True once the user checks or unchecks a support box. Until then a
    /// scope that grows to 4 or more sequences restores the D4 defaults (m3).
    @ObservationIgnored private var supportBoxesWereToggled = false
    @ObservationIgnored private var isApplyingScopeRules = false

    convenience init(
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL
    ) {
        self.init(
            request: request,
            projectURL: projectURL,
            alignment: IQTreeAlignmentSummary.load(bundleURL: request.bundleURL)
        )
    }

    init(
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL,
        alignment: IQTreeAlignmentSummary?,
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
        self.threadsText = String(Self.defaultThreadCount)
        self.selectedOutgroupRowIDs = []
        self.safeMode = false
        self.keepIdenticalSequences = false
        self.advancedOptionsExpanded = AppUITestConfiguration.current.isEnabled
        self.iqtreePath = ""
        self.extraIQTreeOptions = ""
        self.pendingOptions = nil
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
        IQTreeOptionRules.isModelSelectionOnly(model)
    }

    /// IQ-TREE flags a curated control already sets, mapped to that control's
    /// dialog name. The CLI rejects the same table in the extra arguments (C6).
    static let reservedAdvancedFlags: [String: String] =
        IQTreeOptionRules.reservedFlags.mapValues(\.dialogName)

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

    /// Every in-scope row. The dialog lists display names and the CLI gets row
    /// IDs, which it resolves before names.
    var outgroupCandidates: [IQTreeAlignmentSummary.Row] {
        inScopeRows
    }

    func isOutgroupSelected(rowID: String) -> Bool {
        selectedOutgroupRowIDs.contains(rowID)
    }

    func setOutgroup(rowID: String, selected: Bool) {
        guard outgroupCandidates.contains(where: { $0.id == rowID }) else { return }
        if selected {
            selectedOutgroupRowIDs.insert(rowID)
        } else {
            selectedOutgroupRowIDs.remove(rowID)
        }
    }

    private var orderedOutgroupRowIDs: [String] {
        outgroupCandidates.map(\.id).filter { selectedOutgroupRowIDs.contains($0) }
    }

    /// The first in-scope display name that two or more rows share, with
    /// those rows' IDs. The CLI rejects such a scope (C3).
    private var duplicateInScopeDisplayName: (name: String, rowIDs: [String])? {
        var idsByName: [String: [String]] = [:]
        for row in inScopeRows {
            idsByName[row.displayName, default: []].append(row.id)
        }
        for row in inScopeRows {
            if let ids = idsByName[row.displayName], ids.count > 1 {
                return (row.displayName, ids)
            }
        }
        return nil
    }

    // MARK: - Threads (D6, revised)

    /// One thread for every scope. With more threads IQ-TREE 3 gives slightly
    /// different branch lengths on each run, even with the same seed. The
    /// field stays editable and the count is always recorded.
    static let defaultThreadCount = 1

    /// The -b and --lbp notice under the additional parameters, or nil when neither is there.
    /// The CLI records no support labels for these flags (review m8).
    var unorderedSupportCaption: String? {
        guard let arguments = try? AdvancedCommandLineOptions.parse(extraIQTreeOptions),
              IQTreeOptionRules.addsUnorderedSupport(arguments) else {
            return nil
        }
        return Self.unorderedSupportCaptionText
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
        if let duplicate = duplicateInScopeDisplayName {
            let ids = duplicate.rowIDs.joined(separator: ", ")
            return "Rows \(ids) share the display name '\(duplicate.name)'. Tree tips need distinct names."
        }
        if orderedOutgroupRowIDs.count >= inScopeSequenceCount {
            return "The outgroup must leave at least one sequence in the ingroup."
        }
        guard let columnCount = inScopeColumnCount, columnCount > 0 else {
            return "The selected columns could not be read."
        }
        if let message = modelValidationMessage {
            return message
        }
        let columnText = effectiveScope == .selected ? request.columns : nil
        if sequenceType == .codon,
           let ranges = IQTreeOptionRules.columnRanges(columnText, alignedLength: alignment?.alignedLength ?? columnCount),
           let message = IQTreeOptionRules.codonFrameMessage(
               columnRanges: ranges,
               wholeAlignment: (columnText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           ) {
            return message
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
                return "Seed must be a whole number from 1 to 2147483647."
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
            outgroup: orderedOutgroupRowIDs,
            safeMode: safeMode,
            keepIdenticalSequences: keepIdenticalSequences,
            iqtreePath: trimmedOptional(iqtreePath),
            extraIQTreeOptions: extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Scope rules

    private func applyScopeRules() {
        isApplyingScopeRules = true
        defer { isApplyingScopeRules = false }
        if isBranchSupportAvailable == false {
            bootstrapEnabled = false
            alrtEnabled = false
        } else if supportBoxesWereToggled == false {
            bootstrapEnabled = true
            alrtEnabled = true
        }
        let candidates = Set(outgroupCandidates.map(\.id))
        let kept = selectedOutgroupRowIDs.intersection(candidates)
        if kept != selectedOutgroupRowIDs {
            selectedOutgroupRowIDs = kept
        }
    }

    private func noteSupportBoxChange() {
        if isApplyingScopeRules == false {
            supportBoxesWereToggled = true
        }
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
