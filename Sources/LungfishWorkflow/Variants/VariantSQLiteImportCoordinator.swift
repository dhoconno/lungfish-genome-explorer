import Foundation
import LungfishIO

public actor VariantSQLiteImportCoordinator {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void
    public typealias CancellationHandler = @Sendable () -> Bool
    public typealias FreshImporter = @Sendable (
        VariantSQLiteImportRequest,
        ProgressHandler?,
        CancellationHandler?
    ) throws -> Int
    public typealias ResumeImporter = @Sendable (
        URL,
        ProgressHandler?,
        CancellationHandler?
    ) throws -> Int
    public typealias VariantInfoMaterializer = @Sendable (
        URL,
        ProgressHandler?,
        CancellationHandler?
    ) throws -> Int
    public typealias ImportStateReader = @Sendable (URL) -> String?
    public typealias MetadataReader = @Sendable (URL, String) -> String?
    public typealias VariantsTableProbe = @Sendable (URL) -> Bool

    private let fileManager: FileManager
    private let freshImporter: FreshImporter
    private let resumeImporter: ResumeImporter
    private let materializer: VariantInfoMaterializer
    private let importStateReader: ImportStateReader
    private let metadataReader: MetadataReader
    private let variantsTableProbe: VariantsTableProbe

    public init(
        fileManager: FileManager = .default,
        freshImporter: @escaping FreshImporter = VariantSQLiteImportCoordinator.defaultFreshImport,
        resumeImporter: @escaping ResumeImporter = VariantSQLiteImportCoordinator.defaultResumeImport,
        materializer: @escaping VariantInfoMaterializer = VariantSQLiteImportCoordinator.defaultMaterializeVariantInfo,
        importStateReader: @escaping ImportStateReader = VariantDatabase.importState(at:),
        metadataReader: @escaping MetadataReader = VariantDatabase.metadataValue(at:key:),
        variantsTableProbe: @escaping VariantsTableProbe = VariantDatabase.hasVariantsTable(at:)
    ) {
        self.fileManager = fileManager
        self.freshImporter = freshImporter
        self.resumeImporter = resumeImporter
        self.materializer = materializer
        self.importStateReader = importStateReader
        self.metadataReader = metadataReader
        self.variantsTableProbe = variantsTableProbe
    }

    public func importNormalizedVCF(
        request: VariantSQLiteImportRequest,
        progressHandler: ProgressHandler? = nil,
        shouldCancel: CancellationHandler? = nil
    ) async throws -> VariantSQLiteImportResult {
        let dbURL = request.outputDatabaseURL
        let detectedImportState = importStateReader(dbURL)
        let hasDatabaseFile = fileManager.fileExists(atPath: dbURL.path)
        var variantCount = 0
        var didResumeIndexBuild = false
        var didResumeMaterialization = false

        func reopenVariantCount() throws -> Int {
            try VariantDatabase(url: dbURL).totalCount()
        }

        if detectedImportState == "indexing" {
            didResumeIndexBuild = true
            variantCount = try resumeImporter(dbURL, progressHandler, shouldCancel)
        } else if detectedImportState == "inserting" {
            if hasDatabaseFile {
                try? fileManager.removeItem(at: dbURL)
            }
            variantCount = try freshImport(request: request, progressHandler: progressHandler, shouldCancel: shouldCancel)
        } else if metadataReader(dbURL, "materialize_state") == "materializing" {
            didResumeMaterialization = true
            variantCount = try reopenVariantCount()
        } else if hasDatabaseFile && detectedImportState == nil && variantsTableProbe(dbURL) {
            try? fileManager.removeItem(at: dbURL)
            variantCount = try freshImport(request: request, progressHandler: progressHandler, shouldCancel: shouldCancel)
        } else {
            variantCount = try freshImport(request: request, progressHandler: progressHandler, shouldCancel: shouldCancel)
        }

        if importStateReader(dbURL) == "indexing" {
            didResumeIndexBuild = true
            variantCount = try resumeImporter(dbURL, progressHandler, shouldCancel)
        } else if variantCount == 0 {
            variantCount = try reopenVariantCount()
        }

        let materializeState = metadataReader(dbURL, "materialize_state")
        if materializeState == "materializing" {
            didResumeMaterialization = true
        }
        if materializeState == "materializing" || request.materializeVariantInfo {
            let database = try VariantDatabase(url: dbURL)
            if materializeState == "materializing" || database.variantInfoSkipped {
                _ = try materializer(dbURL, progressHandler, shouldCancel)
            }
        }

        return VariantSQLiteImportResult(
            databaseURL: dbURL,
            variantCount: variantCount == 0 ? (try? reopenVariantCount()) ?? 0 : variantCount,
            didResumeIndexBuild: didResumeIndexBuild,
            didResumeMaterialization: didResumeMaterialization
        )
    }

    private func freshImport(
        request: VariantSQLiteImportRequest,
        progressHandler: ProgressHandler?,
        shouldCancel: CancellationHandler?
    ) throws -> Int {
        do {
            return try freshImporter(request, progressHandler, shouldCancel)
        } catch {
            if importStateReader(request.outputDatabaseURL) == "indexing" {
                return try resumeImporter(request.outputDatabaseURL, progressHandler, shouldCancel)
            }
            throw error
        }
    }

    public static func defaultFreshImport(
        request: VariantSQLiteImportRequest,
        progressHandler: ProgressHandler?,
        shouldCancel: CancellationHandler?
    ) throws -> Int {
        try VariantDatabase.createFromVCF(
            vcfURL: request.normalizedVCFURL,
            outputURL: request.outputDatabaseURL,
            sourceFile: request.sourceFile,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel,
            importSemantics: request.importSemantics,
            importProfile: request.importProfile
        )
    }

    public static func defaultResumeImport(
        dbURL: URL,
        progressHandler: ProgressHandler?,
        shouldCancel: CancellationHandler?
    ) throws -> Int {
        try VariantDatabase.resumeImport(
            existingDBURL: dbURL,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel
        )
    }

    public static func defaultMaterializeVariantInfo(
        dbURL: URL,
        progressHandler: ProgressHandler?,
        shouldCancel: CancellationHandler?
    ) throws -> Int {
        try VariantDatabase.materializeVariantInfo(
            existingDBURL: dbURL,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel
        )
    }
}
