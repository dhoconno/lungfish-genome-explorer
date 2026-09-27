// MSADiscriminatingSitesInspectorModel.swift - State for the MSA Inspector's Discriminating Sites section
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow
import Observation

/// Drives the "Discriminating Sites" section of the MSA Inspector.
///
/// The user marks each alignment row as a target, an exclusion, or skipped, or
/// points at a FASTA / reference bundle of exclusion sequences, sets the
/// tolerance and window length, and runs the analysis. The run is always
/// `lungfish-cli msa discriminating-sites` through the Operation Center, with the
/// argv `CLIMSAActionCommandBuilder` builds from `makeRequest()`, so the tables
/// shown here are read back from the JSON report the CLI wrote and the
/// provenance sidecar is the one a terminal run would leave.
@Observable
@MainActor
final class MSADiscriminatingSitesInspectorModel {
    enum RowRole: String, CaseIterable, Identifiable, Sendable {
        case target = "Target"
        case exclusion = "Exclusion"
        case skip = "Skip"

        var id: String { rawValue }
    }

    enum ExclusionSource: String, CaseIterable, Identifiable, Sendable {
        case rows = "Rows in this alignment"
        case file = "Sequences from a file"

        var id: String { rawValue }
    }

    enum ExportFormat: String, Sendable {
        case tsv
        case json
    }

    enum Status: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    struct RowOption: Identifiable, Equatable, Sendable {
        /// The bundle row ID, which the CLI accepts as a row name.
        let id: String
        /// The display name shown in the viewport and used in argv when unambiguous.
        let name: String
    }

    /// A reference bundle or FASTA the project offers as an exclusion panel.
    struct ExclusionFileOption: Identifiable, Equatable, Sendable {
        var id: String { url.path }
        let name: String
        let url: URL
    }

    /// One row of the sortable site table, flattened from the CLI's report.
    struct SiteRow: Identifiable, Equatable, Sendable {
        var id: Int { column }
        /// 1-based alignment column.
        let column: Int
        /// 1-based template position, or `nil` in a template gap.
        let templatePosition: Int?
        let targetBase: String
        let exclusionDifferenceCount: Int
        let exclusionMatchCount: Int
        let exclusionNoCallCount: Int
        let exclusionBases: String
        /// "name:base" for each differing exclusion, in report order.
        let exclusionNames: String
        let dissentingTargets: String

        /// Sort key that keeps template gaps after every placed column.
        var templateSortKey: Int { templatePosition ?? Int.max }
        var templatePositionText: String { templatePosition.map(String.init) ?? "gap" }
    }

    struct WindowRow: Identifiable, Equatable, Sendable {
        var id: String { "\(startColumn)-\(endColumn)" }
        let startColumn: Int
        let endColumn: Int
        let startTemplatePosition: Int?
        let endTemplatePosition: Int?
        let siteCount: Int
        let templatePositions: [Int]

        var spanText: String {
            let start = startTemplatePosition.map(String.init) ?? "-"
            let end = endTemplatePosition.map(String.init) ?? "-"
            return "\(start)-\(end)"
        }
    }

    let bundleURL: URL
    let rows: [RowOption]
    /// Project reference bundles offered in the exclusion picker.
    private(set) var projectExclusionOptions: [ExclusionFileOption]

    var rolesByRowID: [String: RowRole] = [:]
    var exclusionSource: ExclusionSource = .rows {
        didSet { if oldValue != exclusionSource { discardResult() } }
    }
    var exclusionFileURL: URL? {
        didSet { if oldValue != exclusionFileURL { discardResult() } }
    }
    /// `nil` means the first target, which is the CLI default.
    var templateRowID: String?
    var targetMismatchToleranceText = "0"
    var windowLengthText = "25"
    /// Blank means every exclusion must differ, the CLI default.
    var minimumExclusionDifferencesText = ""
    var highlightsEnabled = true {
        didSet { if oldValue != highlightsEnabled { onHighlightChanged?(self) } }
    }

    private(set) var status: Status = .idle
    private(set) var report: DiscriminatingSitesAnalysis.Report?
    private(set) var sites: [SiteRow] = []
    private(set) var windows: [WindowRow] = []
    /// The TSV the last run wrote, next to its provenance sidecar.
    private(set) var lastOutputURL: URL?
    var siteSortOrder: [KeyPathComparator<SiteRow>] = [KeyPathComparator(\.column)]
    var selectedSiteColumn: Int? {
        didSet {
            guard let selectedSiteColumn, selectedSiteColumn != oldValue else { return }
            onJumpRequested?(selectedSiteColumn)
        }
    }

    /// Set by the Inspector to run the CLI through the Operation Center.
    var onRunRequested: ((MSADiscriminatingSitesInspectorModel) -> Void)?
    /// Set by the Inspector to re-run the CLI into a user-chosen destination.
    var onExportRequested: ((MSADiscriminatingSitesInspectorModel, ExportFormat) -> Void)?
    /// Set by the Inspector to push the highlight to the viewport.
    var onHighlightChanged: ((MSADiscriminatingSitesInspectorModel) -> Void)?
    /// Set by the Inspector to select and centre a 1-based column in the viewport.
    var onJumpRequested: ((Int) -> Void)?
    /// Set by the Inspector to open a file chooser for the exclusion sequences.
    var onChooseExclusionFileRequested: ((MSADiscriminatingSitesInspectorModel) -> Void)?

    var pasteboard: PasteboardWriting = DefaultPasteboard()

    init(
        bundleURL: URL,
        rows: [RowOption],
        projectExclusionOptions: [ExclusionFileOption]? = nil
    ) {
        self.bundleURL = bundleURL
        self.rows = rows
        self.projectExclusionOptions = projectExclusionOptions
            ?? Self.projectExclusionOptions(near: bundleURL)
        // Every row starts as a target; the user names the exclusions.
        rolesByRowID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, RowRole.target) })
    }

    // MARK: - Roles

    func role(of row: RowOption) -> RowRole {
        rolesByRowID[row.id] ?? .target
    }

    func setRole(_ role: RowRole, for row: RowOption) {
        guard rolesByRowID[row.id] != role else { return }
        rolesByRowID[row.id] = role
        if role != .target, templateRowID == row.id {
            templateRowID = nil
        }
        discardResult()
    }

    func setAllRoles(_ role: RowRole) {
        for row in rows { rolesByRowID[row.id] = role }
        if role != .target { templateRowID = nil }
        discardResult()
    }

    var targetRows: [RowOption] { rows.filter { role(of: $0) == .target } }
    var exclusionRows: [RowOption] { rows.filter { role(of: $0) == .exclusion } }
    var skippedRows: [RowOption] { rows.filter { role(of: $0) == .skip } }

    // MARK: - Validation and request

    /// Why the run cannot start, or `nil` when it can.
    var validationMessage: String? {
        do {
            _ = try makeRequest()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canRun: Bool { validationMessage == nil && status != .running }

    struct ValidationError: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The CLI request for the current selections, or a validation error naming
    /// the first thing the user must fix.
    func makeRequest() throws -> MSADiscriminatingSitesRequest {
        let targets = targetRows
        guard !targets.isEmpty else {
            throw ValidationError(message: "Mark at least one row as a target.")
        }
        let tolerance = try wholeNumber(targetMismatchToleranceText, "Target mismatch tolerance", minimum: 0)
        guard tolerance < targets.count else {
            throw ValidationError(
                message: "Target mismatch tolerance must be smaller than the number of target rows (\(targets.count)).")
        }
        let windowLength = try wholeNumber(windowLengthText, "Window length", minimum: 1)
        let minimumDifferences: Int?
        if minimumExclusionDifferencesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            minimumDifferences = nil
        } else {
            minimumDifferences = try wholeNumber(minimumExclusionDifferencesText, "Exclusions that must differ", minimum: 1)
        }

        var exclusionNames: String?
        var exclusionSequencesURL: URL?
        switch exclusionSource {
        case .rows:
            let exclusions = exclusionRows
            guard !exclusions.isEmpty else {
                throw ValidationError(message: "Mark at least one row as an exclusion, or choose exclusion sequences from a file.")
            }
            exclusionNames = exclusions.map(argumentName(for:)).joined(separator: ",")
        case .file:
            guard let exclusionFileURL else {
                throw ValidationError(message: "Choose the FASTA file or reference bundle holding the exclusion sequences.")
            }
            exclusionSequencesURL = exclusionFileURL
        }

        // The CLI's default target set is every row not named by --exclusions, so
        // `--targets` is only needed when a row is left out of both roles. With
        // exclusions from a file every non-target row is left out, including one
        // still carrying the Exclusion role from the rows mode.
        let leftOutRows: [RowOption]
        switch exclusionSource {
        case .rows: leftOutRows = skippedRows
        case .file: leftOutRows = rows.filter { role(of: $0) != .target }
        }
        let targetNames = leftOutRows.isEmpty ? nil : targets.map(argumentName(for:)).joined(separator: ",")
        var template: String?
        if let templateRowID, let templateRow = targets.first(where: { $0.id == templateRowID }),
           templateRow.id != targets[0].id {
            template = argumentName(for: templateRow)
        }

        return MSADiscriminatingSitesRequest(
            bundleURL: bundleURL,
            targets: targetNames,
            exclusions: exclusionNames,
            exclusionSequencesURL: exclusionSequencesURL,
            template: template,
            targetMismatchTolerance: tolerance,
            minimumExclusionDifferences: minimumDifferences,
            windowLength: windowLength
        )
    }

    /// The name the CLI is given for a row: its display name, unless that name is
    /// shared by another row or would split on the CLI's comma separator, in
    /// which case the row ID (which the CLI also accepts) is unambiguous.
    func argumentName(for row: RowOption) -> String {
        let duplicated = rows.filter { $0.name == row.name }.count > 1
        if duplicated || row.name.contains(",") || row.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return row.id
        }
        return row.name
    }

    private func wholeNumber(_ text: String, _ title: String, minimum: Int) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= minimum else {
            throw ValidationError(message: "\(title) must be a whole number of at least \(minimum).")
        }
        return value
    }

    // MARK: - Running and results

    func requestRun() {
        guard canRun else { return }
        onRunRequested?(self)
    }

    func requestExport(_ format: ExportFormat) {
        guard validationMessage == nil else { return }
        onExportRequested?(self, format)
    }

    func requestChooseExclusionFile() {
        onChooseExclusionFileRequested?(self)
    }

    func markRunning() {
        status = .running
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }

    /// Reads the JSON report the CLI wrote and fills the tables from it.
    func loadReport(jsonURL: URL, outputURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(DiscriminatingSitesAnalysis.Report.self, from: data)
        apply(report: decoded, outputURL: outputURL)
    }

    func apply(report: DiscriminatingSitesAnalysis.Report, outputURL: URL?) {
        self.report = report
        lastOutputURL = outputURL
        sites = report.sites.map { site in
            SiteRow(
                column: site.column,
                templatePosition: site.templatePosition,
                targetBase: site.targetBase,
                exclusionDifferenceCount: site.exclusionDifferenceCount,
                exclusionMatchCount: site.exclusionMatchCount,
                exclusionNoCallCount: site.exclusionNoCallCount,
                exclusionBases: site.exclusionBases,
                exclusionNames: site.exclusionDifferences.map { "\($0.name):\($0.base)" }.joined(separator: "; "),
                dissentingTargets: site.dissentingTargets.map { "\($0.name):\($0.base)" }.joined(separator: "; ")
            )
        }
        windows = report.windows.map { window in
            WindowRow(
                startColumn: window.startColumn,
                endColumn: window.endColumn,
                startTemplatePosition: window.startTemplatePosition,
                endTemplatePosition: window.endTemplatePosition,
                siteCount: window.siteCount,
                templatePositions: window.templatePositions
            )
        }
        selectedSiteColumn = nil
        status = .ready
        onHighlightChanged?(self)
    }

    /// Clears a stale result when the selections that produced it change.
    func discardResult() {
        let hadResult = report != nil
        report = nil
        sites = []
        windows = []
        lastOutputURL = nil
        selectedSiteColumn = nil
        if status != .running { status = .idle }
        if hadResult { onHighlightChanged?(self) }
    }

    var sortedSites: [SiteRow] { sites.sorted(using: siteSortOrder) }

    var summaryLines: [String] {
        report.map(DiscriminatingSitesReportFormatter.summaryLines(for:)) ?? []
    }

    /// The per-site TSV exactly as the CLI writes it.
    var siteTSV: String? {
        report.map(DiscriminatingSitesReportFormatter.siteTSV(for:))
    }

    @discardableResult
    func copyTSV() -> Bool {
        guard let siteTSV else { return false }
        pasteboard.setString(siteTSV)
        return true
    }

    /// The highlight the viewport should draw, or `nil` to clear it.
    var highlight: MSADiscriminatingSitesHighlight? {
        guard highlightsEnabled, let report else { return nil }
        var roles: [String: MSADiscriminatingSitesHighlight.RowRole] = [:]
        for row in rows {
            switch role(of: row) {
            case .target: roles[row.id] = .target
            case .exclusion: roles[row.id] = exclusionSource == .rows ? .exclusion : nil
            case .skip: break
            }
        }
        return MSADiscriminatingSitesHighlight(
            columns: report.sites.map(\.column),
            rowRolesByID: roles,
            targetCount: report.targetNames.count,
            exclusionCount: report.exclusionNames.count,
            exclusionSourceName: exclusionSource == .file
                ? exclusionFileURL?.deletingPathExtension().lastPathComponent
                : nil
        )
    }

    /// Selects the site row and centres the viewport on it; re-selecting the
    /// same row still re-centres.
    func jump(toColumn column: Int) {
        if selectedSiteColumn == column {
            onJumpRequested?(column)
        } else {
            selectedSiteColumn = column
        }
    }

    // MARK: - Project exclusion candidates

    /// The `.lungfishref` bundles in the enclosing project's Reference Sequences
    /// folder, which is where the demo projects keep their exclusion panels.
    nonisolated static func projectExclusionOptions(near bundleURL: URL) -> [ExclusionFileOption] {
        guard let projectURL = ProjectTempDirectory.findProjectRoot(bundleURL) else { return [] }
        return projectExclusionOptions(inProject: projectURL)
    }

    nonisolated static func projectExclusionOptions(inProject projectURL: URL) -> [ExclusionFileOption] {
        let folder = projectURL.appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "lungfishref" }
            .map { ExclusionFileOption(name: $0.deletingPathExtension().lastPathComponent, url: $0.standardizedFileURL) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
