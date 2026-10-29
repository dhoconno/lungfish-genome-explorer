// EsVirituAnalysisRunTool.swift - EsViritu detection on the analysis run executor, its options and its plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// EsViritu viral detection as a tool of the analysis run executor (2.7 A9, scope rows A1 to A4).
///
/// The plan refuses what can be refused before any folder exists, with the exit codes the command
/// has always used, resolves the database and groups the samples. A plain `--output` run is one
/// sample in one folder, as the command wrote it before (E2). A `--project` or `--batch` run is a
/// batch root with one folder per sample, named through the executor's one sanitizer, and that
/// name is also EsViritu's `-s`, so `build-db esviritu` finds every sample's tables (R4, BIO O5).
/// A unit materializes a virtual bundle into `<root>/.lungfish-esviritu-inputs/` and keeps it (E3),
/// records the lineage of its inputs to their bundles (D5), runs `EsVirituPipeline` and parses the
/// detection table, failing on a column change (D10). The finalize writes the batch summary, the
/// manifest, the viewer index and the source bundle entries of a batch root.
public struct EsVirituAnalysisRunTool: AnalysisRunTool {
    public typealias Unit = EsVirituSampleUnit
    public typealias UnitResult = EsVirituSampleResult

    /// The workflow name of the root record.
    public static let workflowName = "lungfish.esviritu.detect"
    /// The folder of the result root that keeps materialized and joined inputs (E3).
    public static let materializationDirectoryName = ".lungfish-esviritu-inputs"
    /// The batch summary at a batch root.
    public static let summaryFilename = "esviritu-batch-summary.tsv"
    /// The heading of a failed sample's log tail on an `error` log line, the words the app's batch
    /// row has always written before it (UX D6). A run of one sample sends the tail as the detail
    /// of its `failed` line instead, without a heading.
    public static let logTailHeading = "EsViritu log (last lines):\n"
    /// The database identity status of an EsViritu run whose database no install receipt pins, the
    /// word its record has always had. The catalog pins no digest and nothing hashes the database
    /// folder per run (E9, SWIFT X4). A run whose database has an install receipt that adds up
    /// records `pinned` and the receipt's digest instead (DB-IDENTITY, 3.1).
    public static let databaseIdentityStatus = "unpinned"
    /// Where the database of a run came from, recorded as `databaseOrigin` (E9).
    enum DatabaseOrigin {
        /// The database the app installed, used without `--db` or named by it.
        static let installed = "installed"
        /// Another folder `--db` names, which the bundled catalog does not describe.
        static let given = "given"
    }

    /// The roles of the typed artifacts on the `complete` line.
    public enum ArtifactRole {
        public static let detections = "esviritu-detections"
        public static let resultSidecar = "esviritu-result"
        public static let database = "classifier-database"
        public static let batchSummary = "batch-summary"
        public static let batchManifest = "batch-manifest"
    }

    public let options: EsVirituAnalysisRunOptions
    /// Whether the command was given `--batch`, which also sets the terminal policy.
    public let groupsSamples: Bool
    let pipeline: EsVirituPipeline
    let materializer: any CLISequenceInputMaterializing & Sendable
    let installedDatabase: @Sendable () async -> URL?
    let expandInputs: @Sendable ([URL]) throws -> [URL]
    let reporter: (any EsVirituRunReporting)?

    /// - Parameters:
    ///   - installedDatabase: The installed database, or nil when none is installed. The default asks
    ///     `EsVirituDatabaseManager`.
    ///   - expandInputs: Turns the inputs as given into the files and bundles the run reads, such as
    ///     the FASTQ files of a folder. A thrown error refuses the request with exit 3.
    public init(
        options: EsVirituAnalysisRunOptions,
        groupsSamples: Bool,
        pipeline: EsVirituPipeline = .shared,
        materializer: any CLISequenceInputMaterializing & Sendable,
        installedDatabase: @escaping @Sendable () async -> URL? = EsVirituAnalysisRunTool.installedDatabase,
        expandInputs: @escaping @Sendable ([URL]) throws -> [URL] = { $0 },
        reporter: (any EsVirituRunReporting)? = nil
    ) {
        self.options = options
        self.groupsSamples = groupsSamples
        self.pipeline = pipeline
        self.materializer = materializer
        self.installedDatabase = installedDatabase
        self.expandInputs = expandInputs
        self.reporter = reporter
    }

    public var identity: AnalysisRunIdentity {
        AnalysisRunIdentity(toolID: .esviritu, workflowName: Self.workflowName)
    }

    /// A batch completes while one sample completes, with a warning for each failed one, as the
    /// app's EsViritu batch does. One sample fails the run when it fails.
    public var terminalPolicy: AnalysisRunTerminalPolicy {
        groupsSamples ? .warnOnFailedUnits : .failOnAnyFailedUnit
    }

    /// The installed EsViritu database, or nil when none is installed.
    @Sendable public static func installedDatabase() async -> URL? {
        let manager = EsVirituDatabaseManager.shared
        guard await manager.isInstalled() else { return nil }
        return await manager.databaseURL
    }

    // MARK: - P0

    public func plan(
        _ request: AnalysisRunRequest,
        context: AnalysisRunPlanningContext
    ) async throws -> AnalysisRunPlan<EsVirituSampleUnit> {
        if let conflict = options.usageConflict {
            throw EsVirituAnalysisRunRefusal.input(conflict)
        }
        let inputURLs: [URL]
        do {
            inputURLs = try expandInputs(request.inputs)
        } catch {
            throw EsVirituAnalysisRunRefusal.input(error.localizedDescription)
        }
        guard !inputURLs.isEmpty else {
            throw EsVirituAnalysisRunRefusal.input("At least one --input file is required")
        }
        let extraArguments: [String]
        do {
            extraArguments = try AdvancedCommandLineOptions.parse(options.extraArguments)
        } catch {
            throw EsVirituAnalysisRunRefusal.input(error.localizedDescription)
        }
        for inputURL in inputURLs.map(\.standardizedFileURL) {
            if let message = CLISequenceInputMaterialization.unsupportedSequenceInputMessage(
                for: inputURL,
                operationName: "EsViritu detection"
            ) {
                throw EsVirituAnalysisRunRefusal.input(message)
            }
            if !CLISequenceInputMaterialization.requiresMaterialization(inputURL),
               SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) == nil {
                throw EsVirituAnalysisRunRefusal.input(
                    CLISequenceInputMaterializationError.unreadableSequenceInput(inputURL.path).localizedDescription
                )
            }
        }

        let units = try request.groupsSamples
            ? batchUnits(inputURLs)
            : [oneSampleUnit(inputURLs)]
        let database = try await resolveDatabase()
        let settings = EsVirituRunSettings(
            databasePath: database.url,
            threads: options.threads,
            qualityFilter: options.qualityFilter,
            extraArguments: extraArguments
        )
        let layout: AnalysisRunLayout
        switch request.destination {
        case .project:
            layout = .batchRoot
        case .directory:
            layout = request.groupsSamples ? .batchRoot : .singleFolder
        }
        return AnalysisRunPlan(
            layout: layout,
            units: units.map { unit in
                AnalysisRunPlannedUnit(
                    label: unit.label,
                    value: EsVirituSampleUnit(
                        inputs: unit.inputs,
                        readFormat: unit.format,
                        inputLayout: unit.layout,
                        plansReadSet: unit.plansReadSet,
                        settings: settings
                    )
                )
            },
            options: runOptions(settings: settings, databaseIsInstalled: database.isInstalled, sampleCount: units.count)
        )
    }

    private struct PlannedSample {
        let label: String
        let inputs: [URL]
        let format: EsVirituReadFormat
        let layout: FASTQReadLayoutClassification?
        let plansReadSet: Bool
    }

    /// The one sample of a run without `--batch`, read as the command has always read it.
    private func oneSampleUnit(_ inputURLs: [URL]) throws -> PlannedSample {
        guard let sampleName = options.sampleName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sampleName.isEmpty else {
            throw EsVirituAnalysisRunRefusal.input("--sample names the sample. Give it, or give --batch to name each sample after its files.")
        }
        let resolved = try Self.resolveReadFormat(options.readFormat, pairedEnd: options.pairedEnd, inputURLs: inputURLs)
        // A `.lungfishfastq` bundle is counted once it resolves to the files it holds.
        let namesABundle = inputURLs.contains { SequenceInputResolver.enclosingFASTQBundleURL(for: $0) != nil }
        if !namesABundle, let message = Self.inputCountError(format: resolved.format, fileCount: inputURLs.count) {
            throw EsVirituAnalysisRunRefusal.input(message)
        }
        return PlannedSample(
            label: options.sampleName ?? sampleName,
            inputs: inputURLs,
            format: resolved.format,
            layout: resolved.layout,
            plansReadSet: options.readFormat == .auto && !options.pairedEnd
        )
    }

    /// The samples of a `--batch` run, grouped as the app's EsViritu wizard groups them (E8), each
    /// with the read format the wizard plans for it from its files.
    private func batchUnits(_ inputURLs: [URL]) throws -> [PlannedSample] {
        if options.sampleName != nil {
            throw EsVirituAnalysisRunRefusal.input("--batch names each sample after its files, so it takes no --sample.")
        }
        guard options.readFormat == .auto, !options.pairedEnd else {
            throw EsVirituAnalysisRunRefusal.input("--batch plans each sample's read layout from its files, so it takes --read-format auto and no --paired.")
        }
        return MetagenomicsSampleGrouper.group(inputURLs).map { sample in
            let plan = EsVirituSampleReadPlan.plan(for: sample)
            return PlannedSample(
                label: sample.sampleId,
                inputs: sample.inputFiles,
                format: plan.format,
                layout: plan.layout,
                plansReadSet: !sample.isPairedEnd
            )
        }
    }

    /// The database folder of the run, and whether it is the one the app installed. That is so
    /// without `--db`, and when the folder `--db` names and the installed one are the same folder
    /// once symlinks are resolved and the paths standardized.
    private func resolveDatabase() async throws -> (url: URL, isInstalled: Bool) {
        if let path = options.databasePath {
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw EsVirituAnalysisRunRefusal.input("Database directory not found: \(path.path)")
            }
            let installed = await installedDatabase()
            return (path, installed.map { Self.namesSameFolder($0, path) } ?? false)
        }
        guard let installed = await installedDatabase() else {
            throw EsVirituAnalysisRunRefusal.dependency(
                "EsViritu database not found. Download it first: lungfish-cli esviritu download-db"
            )
        }
        return (installed, true)
    }

    /// Whether two paths name one folder, with symlinks resolved and the paths standardized.
    static func namesSameFolder(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path
            == second.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Read formats

    /// Resolves `--read-format` and `--paired` into the EsViritu read format. `auto` classifies a
    /// single input with ``FASTQReadLayoutClassifier`` and runs several inputs unpaired.
    public static func resolveReadFormat(
        _ choice: EsVirituAnalysisRunOptions.ReadFormatChoice,
        pairedEnd: Bool,
        inputURLs: [URL]
    ) throws -> (format: EsVirituReadFormat, layout: FASTQReadLayoutClassification?) {
        if pairedEnd {
            guard choice == .auto || choice == .paired else {
                throw EsVirituAnalysisRunRefusal.input("--paired conflicts with --read-format \(choice.rawValue).")
            }
            return (.paired, nil)
        }
        switch choice {
        case .unpaired: return (.unpaired, nil)
        case .paired: return (.paired, nil)
        case .interleaved: return (.interleaved, nil)
        case .auto:
            guard inputURLs.count == 1 else { return (.unpaired, nil) }
            let layout = FASTQReadLayoutClassifier.classify(inputURL: inputURLs[0])
            return (EsVirituReadFormat.forSingleFile(layout.layout), layout)
        }
    }

    /// Why `fileCount` input files do not fit `format`, or nil when they do.
    public static func inputCountError(format: EsVirituReadFormat, fileCount: Int) -> String? {
        if format == .paired && fileCount != 2 {
            return "Paired-end mode requires exactly 2 input files, got \(fileCount)"
        }
        if format == .interleaved && fileCount != 1 {
            return "Interleaved mode requires exactly 1 input file, got \(fileCount)"
        }
        return nil
    }

    // MARK: - Root record options

    /// The run-level options of the root record. Each sample's own facts stay in its unit record,
    /// and a one-folder run adds them in its unit. The database identity follows E9 and DB-IDENTITY
    /// (3.1). Every run records where its database came from (`databaseOrigin`), the sizes of the
    /// database's core files and a status. A database whose install receipt adds up to its own digest
    /// also records that digest as `databaseDigest` and says `pinned`, a receipt that does not add up
    /// is named in `databaseIdentityNote`, and a database with no receipt says `unpinned`. The receipt
    /// sits in the database folder or in its parent, and it names the version, which the bundled
    /// catalog names only for a database with no receipt. Nothing is hashed. Only the database the
    /// app installed also records the catalog entry it came from. Another folder `--db` names, such
    /// as an older release or a custom build, records no catalog entry, which would not describe it,
    /// and takes its version from its own receipt when it has one.
    private func runOptions(
        settings: EsVirituRunSettings,
        databaseIsInstalled: Bool,
        sampleCount: Int
    ) -> AnalysisRootRecordOptions {
        let receipt = MetagenomicsDatabaseReceiptReference.resolve(
            databasePath: settings.databasePath, allowingParentReceipt: true
        )
        var resolved: [String: ParameterValue] = [
            "databasePath": .string(settings.databasePath.path),
            "databaseOrigin": .string(databaseIsInstalled ? Self.DatabaseOrigin.installed : Self.DatabaseOrigin.given),
            "databaseCoreFileSizes": .dictionary(Self.databaseCoreFileSizes(at: settings.databasePath).mapValues { .integer($0) }),
            "sampleCount": .integer(sampleCount),
        ]
        resolved.merge(MetagenomicsDatabaseReceiptReference.identityFacts(of: receipt)) { current, _ in current }
        if databaseIsInstalled, let catalog = ManagedToolLock.bundled.database(id: EsVirituDatabaseManager.catalogID) {
            resolved["databaseCatalogID"] = .string(catalog.id)
            resolved["databaseCatalogVersion"] = .string(receipt?.catalogVersion ?? catalog.version)
            resolved["databaseSourceURL"] = catalog.url.map(ParameterValue.string) ?? .null
            resolved["databaseSourcePolicy"] = .string(catalog.effectiveSourcePolicy.rawValue)
        } else if let version = receipt?.catalogVersion {
            resolved["databaseCatalogVersion"] = .string(version)
        }
        var explicit: [String: ParameterValue] = [
            "batch": .boolean(groupsSamples),
            "qualityFilter": .boolean(settings.qualityFilter),
            "threads": .integer(settings.threads),
            "extraArgs": .string(AdvancedCommandLineOptions.join(settings.extraArguments)),
        ]
        // The read format and `--paired` the user typed are explicit, recorded whether or not a sample runs. The
        // pipeline records the format a run used as a resolved default, since its configuration cannot tell the two
        // apart (E12, SW26 note 4).
        if options.readFormat != .auto {
            explicit["readFormat"] = .string(options.readFormat.rawValue)
        }
        if options.pairedEnd {
            explicit["pairedEnd"] = .boolean(true)
        }
        return AnalysisRootRecordOptions(
            explicit: explicit,
            defaults: [
                "readFormat": .string(EsVirituAnalysisRunOptions.ReadFormatChoice.auto.rawValue),
                "qualityFilter": .boolean(true),
                "extraArgs": .string(""),
            ],
            resolved: resolved
        )
    }

    /// The size of each core file at the top of the database folder, its FASTA, minimap2 index and
    /// metadata tables. A file made at first use, such as a FASTA index, is left out, and nothing is
    /// hashed.
    static func databaseCoreFileSizes(at databaseURL: URL) -> [String: Int] {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: databaseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var sizes: [String: Int] = [:]
        for url in contents where ["fna", "fa", "fasta", "mmi", "tsv"].contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            sizes[url.lastPathComponent] = size
        }
        return sizes
    }
}
