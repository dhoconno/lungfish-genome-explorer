import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
final class ProjectStorageSheetViewModel {
    private enum CleanupSummaryError: Error, LocalizedError {
        case duplicateItemIdentifier

        var errorDescription: String? {
            "The cleanup receipt contains a duplicate item identifier."
        }
    }

    enum State: Equatable {
        case idle
        case scanning
        case ready
        case revalidating
        case cleaning
        case finished
        case cancelled
        case failed
        case stale
    }

    struct CategorySection: Identifiable, Equatable {
        enum Kind: String {
            case workbookArchive
            case workflowStaging
            case temporary
            case notRemovable
        }

        let kind: Kind
        let title: String
        let entries: [ProjectStorageEntry]

        var id: String { kind.rawValue }
        var isCheckable: Bool { kind != .notRemovable }
    }

    let projectURL: URL
    private(set) var boundProjectURL: URL
    let projectIdentity: FileSystemObjectIdentity
    let bindingGeneration: UInt64
    let progressThrottleInterval: TimeInterval
    let allowsCleanup: Bool

    private let bindingIsCurrent: @MainActor () -> Bool
    private let requestCleanup: @MainActor () -> Void
    private let requestClose: @MainActor () -> Void
    private let requestCancellation: @MainActor () -> Void
    private let requestRetryScan: @MainActor () -> Void
    private let requestRetryFailed:
        @MainActor ([ProjectStorageEntry]) -> Void
    private let requestReveal: @MainActor (URL) -> Void

    private(set) var state: State = .idle
    private(set) var entries: [ProjectStorageEntry] = []
    private(set) var selectedEntryIDs: Set<UUID> = []
    private(set) var scanProgress: ProjectStorageScanProgress?
    private(set) var hasPartialScanResults = false
    private(set) var isStale = false
    private(set) var statusMessage = "Ready to scan project storage."
    private(set) var receiptURL: URL?
    private(set) var provenanceURL: URL?
    private(set) var failedEntries: [ProjectStorageEntry] = []
    private(set) var removedAllocatedBytes: UInt64 = 0
    private(set) var cleanupItems:
        [UUID: ProjectStorageCleanupExecutionSummary.Item] = [:]
    private var lastProgressDeliveryTime: TimeInterval?
    private var cancellationRequested = false
    private var scanRetryAvailable = false

    var onChange: (@MainActor () -> Void)?

    init(
        projectURL: URL,
        projectIdentity: FileSystemObjectIdentity,
        bindingGeneration: UInt64 = 0,
        progressThrottleInterval: TimeInterval = 0.1,
        allowsCleanup: Bool = true,
        bindingIsCurrent: @escaping @MainActor () -> Bool,
        requestCleanup: @escaping @MainActor () -> Void,
        requestClose: @escaping @MainActor () -> Void,
        requestCancellation: @escaping @MainActor () -> Void,
        requestRetryScan: @escaping @MainActor () -> Void,
        requestRetryFailed:
            @escaping @MainActor ([ProjectStorageEntry]) -> Void,
        requestReveal: @escaping @MainActor (URL) -> Void
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.boundProjectURL = projectURL.standardizedFileURL
        self.projectIdentity = projectIdentity
        self.bindingGeneration = bindingGeneration
        self.progressThrottleInterval = max(0, progressThrottleInterval)
        self.allowsCleanup = allowsCleanup
        self.bindingIsCurrent = bindingIsCurrent
        self.requestCleanup = requestCleanup
        self.requestClose = requestClose
        self.requestCancellation = requestCancellation
        self.requestRetryScan = requestRetryScan
        self.requestRetryFailed = requestRetryFailed
        self.requestReveal = requestReveal
    }

    var sheetTitle: String {
        let name = projectURL.deletingPathExtension().lastPathComponent
        return "Project Storage — “\(name)”"
    }

    var categorySections: [CategorySection] {
        let removable = entries.filter(\.classification.isRemovable)
        let notRemovable = entries.filter {
            !$0.classification.isRemovable
        }
        return [
            CategorySection(
                kind: .workbookArchive,
                title: "Completed workbook publication archives",
                entries: removableEntries(
                    removable,
                    category: .workbookArchive
                )
            ),
            CategorySection(
                kind: .workflowStaging,
                title: "Orphaned workflow staging data",
                entries: removableEntries(
                    removable,
                    category: .workflowStaging
                )
            ),
            CategorySection(
                kind: .temporary,
                title: "Temporary files",
                entries: removableEntries(
                    removable,
                    category: .temporary
                )
            ),
            CategorySection(
                kind: .notRemovable,
                title: "Not Removable",
                entries: notRemovable.sorted {
                    $0.relativePath.localizedStandardCompare(
                        $1.relativePath
                    ) == .orderedAscending
                }
            ),
        ]
    }

    var selectedEntries: [ProjectStorageEntry] {
        entries
            .filter { selectedEntryIDs.contains($0.id) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    var selectedLogicalBytes: UInt64 {
        saturatedTotal(selectedEntries, keyPath: \.logicalBytes)
    }

    var selectedAllocatedBytes: UInt64 {
        saturatedTotal(selectedEntries, keyPath: \.allocatedBytes)
    }

    var selectedAllocatedSizeText: String {
        Self.localizedByteCount(selectedAllocatedBytes)
    }

    var cleanupButtonTitle: String {
        "Move \(selectedAllocatedSizeText) to Trash"
    }

    var estimatedTotalDescription: String {
        let logical = Self.localizedByteCount(selectedLogicalBytes)
        return "Selected estimated on disk: \(selectedAllocatedSizeText); "
            + "logical size: \(logical). "
            + "Items remain recoverable in Trash; empty the Trash to reclaim "
            + "disk space. Filesystem clones may reclaim less."
    }

    var canScan: Bool {
        !isStale
            && state != .scanning
            && state != .revalidating
            && state != .cleaning
    }

    var canCleanup: Bool {
        !isStale
            && allowsCleanup
            && !selectedEntryIDs.isEmpty
            && state == .ready
    }

    var cleanupDisabledReason: String? {
        guard !allowsCleanup else { return nil }
        return "This project is read-only recommended. Storage can be "
            + "reviewed, but items cannot be moved."
    }

    var canRetryScan: Bool {
        !isStale
            && state != .scanning
            && state != .revalidating
            && state != .cleaning
            && scanRetryAvailable
    }

    var canRetryFailed: Bool {
        !isStale && !failedEntries.isEmpty && state == .finished
    }

    var canRevealReceipt: Bool {
        receiptURL != nil
    }

    var trashDestinationURLs: [UUID: URL] {
        cleanupItems.reduce(into: [:]) { partial, pair in
            guard pair.value.state == .movedToTrash,
                  let path = pair.value.trashDestinationPath else {
                return
            }
            partial[pair.key] = URL(fileURLWithPath: path)
        }
    }

    func logicalSizeText(for entry: ProjectStorageEntry) -> String {
        Self.localizedByteCount(entry.logicalBytes)
    }

    func allocatedSizeText(for entry: ProjectStorageEntry) -> String {
        Self.localizedByteCount(entry.allocatedBytes)
    }

    func modifiedDateText(for entry: ProjectStorageEntry) -> String {
        Self.localizedDate(entry.modificationDate)
    }

    func cleanupStatusText(for entry: ProjectStorageEntry) -> String {
        guard let item = cleanupItems[entry.id] else {
            return entry.classification.isRemovable
                ? "Proven removable"
                : entry.classification.reason
        }
        switch item.state {
        case .movedToTrash:
            return "Moved to Trash"
        case .failed:
            return "Failed: \(item.reason ?? "Cleanup did not complete.")"
        case .skipped:
            return "Skipped: \(item.reason ?? "Safety revalidation failed.")"
        case .restoredAfterTrashFailure:
            return "Restored: \(item.reason ?? "Trash was unavailable.")"
        case .quarantineRetained:
            return "Needs attention: "
                + (item.reason ?? "A safe quarantine was retained.")
        case .outcomeUnknown:
            return "Outcome unknown: "
                + (item.reason ?? "Review the durable receipt.")
        default:
            return item.reason ?? item.state.rawValue
        }
    }

    func analysisText(for entry: ProjectStorageEntry) -> String {
        let components = entry.relativePath.split(separator: "/").map(String.init)
        guard let analyses = components.firstIndex(of: "Analyses"),
              components.indices.contains(analyses + 1) else {
            return "Project"
        }
        return components[analyses + 1]
    }

    func categoryAccessibilityLabel(for section: CategorySection) -> String {
        let count = Self.localizedCount(UInt64(section.entries.count))
        let entryWord = section.entries.count == 1 ? "entry" : "entries"
        let allocated = Self.localizedByteCount(
            saturatedTotal(section.entries, keyPath: \.allocatedBytes)
        )
        let logical = Self.localizedByteCount(
            saturatedTotal(section.entries, keyPath: \.logicalBytes)
        )
        let selection: String
        let safety: String
        if section.isCheckable {
            let entryIDs = Set(section.entries.map(\.id))
            if entryIDs.isEmpty
                || entryIDs.isDisjoint(with: selectedEntryIDs) {
                selection = "none selected"
            } else if entryIDs.isSubset(of: selectedEntryIDs) {
                selection = "all selected"
            } else {
                selection = "partially selected"
            }
            safety = "individually proven removable"
        } else {
            selection = "not checkable"
            safety = "not removable"
        }
        return "\(section.title), \(count) \(entryWord), "
            + "\(allocated) estimated on disk, \(logical) logical, "
            + "\(selection), \(safety)."
    }

    func beginScanning() {
        guard revalidateBinding(), canScan else { return }
        state = .scanning
        statusMessage = "Scanning project storage…"
        entries.removeAll()
        selectedEntryIDs.removeAll()
        failedEntries.removeAll()
        cleanupItems.removeAll()
        removedAllocatedBytes = 0
        receiptURL = nil
        provenanceURL = nil
        hasPartialScanResults = false
        scanProgress = nil
        lastProgressDeliveryTime = nil
        cancellationRequested = false
        scanRetryAvailable = false
        notify()
    }

    func bindAuthorityProjectURL(_ projectURL: URL) {
        boundProjectURL = projectURL.standardizedFileURL
    }

    func receiveScanProgress(
        _ progress: ProjectStorageScanProgress,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard (state == .scanning || state == .revalidating),
              !isStale,
              !cancellationRequested else {
            return
        }
        if let lastProgressDeliveryTime,
           now - lastProgressDeliveryTime < progressThrottleInterval {
            return
        }
        lastProgressDeliveryTime = now
        scanProgress = progress
        statusMessage = Self.scanProgressDescription(progress)
        notify()
    }

    func receiveRevalidationCancellation() {
        guard state == .revalidating, !isStale else { return }
        state = .finished
        statusMessage =
            "Revalidation stopped. The failed entries remain available "
            + "to retry."
        scanProgress = nil
        lastProgressDeliveryTime = nil
        cancellationRequested = false
        notify()
    }

    func receiveRevalidationFailure(_ error: Error) {
        guard state == .revalidating, !isStale else { return }
        state = .finished
        statusMessage =
            "Revalidation failed: \(error.localizedDescription) "
            + "The failed entries remain available to retry."
        scanProgress = nil
        lastProgressDeliveryTime = nil
        cancellationRequested = false
        notify()
    }

    func receiveScanResult(_ result: ProjectStorageScanResult) {
        guard acceptScanAuthority(result) else { return }
        applyEntries(result.entries)
        state = .ready
        hasPartialScanResults = false
        scanRetryAvailable = false
        statusMessage = result.entries.isEmpty
            ? "No managed project storage entries were found."
            : "Review the individually classified entries below."
        notify()
    }

    func receiveScanCancellation() {
        guard !isStale else { return }
        state = .cancelled
        entries.removeAll()
        selectedEntryIDs.removeAll()
        statusMessage = "Scan cancelled."
        hasPartialScanResults = false
        scanRetryAvailable = true
        notify()
    }

    func receiveScanFailure(_ error: Error) {
        guard !isStale else { return }
        state = .failed
        entries.removeAll()
        selectedEntryIDs.removeAll()
        statusMessage = "Storage scan failed: \(error.localizedDescription)"
        hasPartialScanResults = false
        scanRetryAvailable = true
        notify()
    }

    func toggleSelection(for entryID: UUID) {
        guard revalidateBinding(),
              let entry = entries.first(where: { $0.id == entryID }),
              entry.classification.isRemovable,
              state != .revalidating,
              state != .cleaning else {
            return
        }
        if selectedEntryIDs.contains(entryID) {
            selectedEntryIDs.remove(entryID)
        } else {
            selectedEntryIDs.insert(entryID)
        }
        notify()
    }

    func toggleSelection(for section: CategorySection) {
        guard section.isCheckable, revalidateBinding() else { return }
        let ids = Set(section.entries.map(\.id))
        if ids.isSubset(of: selectedEntryIDs) {
            selectedEntryIDs.subtract(ids)
        } else {
            selectedEntryIDs.formUnion(ids)
        }
        notify()
    }

    func beginCleanup() {
        guard revalidateBinding(), canCleanup else { return }
        state = .cleaning
        statusMessage = "Preparing a durable cleanup receipt…"
        cancellationRequested = false
        notify()
        requestCleanup()
    }

    func receiveCleanupResult(
        summary: ProjectStorageCleanupExecutionSummary,
        summaryURL: URL,
        provenanceURL: URL
    ) {
        guard revalidateBinding(),
              summary.projectIdentity == projectIdentity,
              URL(fileURLWithPath: summary.projectRoot)
                .standardizedFileURL.path == boundProjectURL.path else {
            markStale()
            return
        }
        do {
            cleanupItems = try Self.validatedCleanupItems(summary.items)
        } catch {
            receiveCleanupFailure(error)
            return
        }
        let movedItemIDs = Set(
            summary.items.compactMap {
                $0.state == .movedToTrash ? $0.itemID : nil
            }
        )
        removedAllocatedBytes = saturatedTotal(
            entries.filter { movedItemIDs.contains($0.id) },
            keyPath: \.allocatedBytes
        )
        receiptURL = summaryURL
        self.provenanceURL = provenanceURL
        let retryableStates:
            Set<ProjectStorageCleanupDispositionRecord.State> = [
                .failed,
                .skipped,
                .restoredAfterTrashFailure,
            ]
        failedEntries = entries.filter { entry in
            guard let item = cleanupItems[entry.id] else { return false }
            return retryableStates.contains(item.state)
                && item.state != .quarantineRetained
                && item.state != .outcomeUnknown
        }
        selectedEntryIDs = Set(failedEntries.map(\.id))
        state = .finished
        let moved = summary.items.filter { $0.state == .movedToTrash }.count
        let failed = summary.items.count - moved
        let movedWord = moved == 1 ? "item" : "items"
        let failedWord = failed == 1 ? "item" : "items"
        statusMessage =
            "\(Self.localizedByteCount(removedAllocatedBytes)) "
            + "removed from the project. "
            + "\(Self.localizedCount(UInt64(moved))) \(movedWord) "
            + "moved to Trash; "
            + "\(Self.localizedCount(UInt64(failed))) \(failedWord) failed. "
            + "Empty the Trash to reclaim disk space. "
            + "No permanent deletion was used."
        notify()
    }

    func receiveCleanupFailure(_ error: Error) {
        guard !isStale else { return }
        state = .failed
        statusMessage = "Cleanup failed safely: \(error.localizedDescription)"
        scanRetryAvailable = false
        notify()
    }

    func prepareRetry(with freshEntries: [ProjectStorageEntry]) {
        guard revalidateBinding() else { return }
        entries = freshEntries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
        selectedEntryIDs = Set(freshEntries.map(\.id))
        state = .cleaning
        statusMessage = "Preparing a new durable receipt for failed entries…"
        receiptURL = nil
        provenanceURL = nil
        cleanupItems.removeAll()
        removedAllocatedBytes = 0
        failedEntries.removeAll()
        cancellationRequested = false
        notify()
    }

    func retryFailed() {
        guard revalidateBinding(), canRetryFailed else { return }
        let entriesToRetry = failedEntries
        state = .revalidating
        statusMessage = "Revalidating failed entries…"
        scanProgress = nil
        lastProgressDeliveryTime = nil
        cancellationRequested = false
        notify()
        requestRetryFailed(entriesToRetry)
    }

    func retryScan() {
        guard revalidateBinding(), canRetryScan else { return }
        requestRetryScan()
    }

    func revealReceipt() {
        guard revalidateBinding(), let receiptURL else { return }
        requestReveal(receiptURL)
    }

    func revealTrashDestination(for entryID: UUID) {
        guard revalidateBinding(),
              let destination = trashDestinationURLs[entryID] else {
            return
        }
        requestReveal(destination)
    }

    @discardableResult
    func handleReturnKey() -> Bool {
        true
    }

    @discardableResult
    func handleEscapeKey() -> Bool {
        if state == .scanning {
            guard !cancellationRequested else { return true }
            cancellationRequested = true
            statusMessage = "Stopping scan…"
            notify()
            requestCancellation()
            return true
        }
        if state == .cleaning {
            guard !cancellationRequested else { return true }
            cancellationRequested = true
            statusMessage = "Stopping after the current item…"
            notify()
            requestCancellation()
            return true
        }
        if state == .revalidating {
            guard !cancellationRequested else { return true }
            cancellationRequested = true
            statusMessage = "Stopping revalidation…"
            notify()
            requestCancellation()
            return true
        }
        requestCancellation()
        state = .cancelled
        notify()
        requestClose()
        return true
    }

    @discardableResult
    func revalidateBinding() -> Bool {
        guard !isStale, bindingIsCurrent() else {
            markStale()
            return false
        }
        return true
    }

    static func localizedByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func localizedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func localizedCount(_ count: UInt64) -> String {
        NumberFormatter.localizedString(
            from: NSNumber(value: count),
            number: .decimal
        )
    }

    static func scanProgressDescription(
        _ progress: ProjectStorageScanProgress
    ) -> String {
        let visited = localizedCount(progress.visitedFileSystemObjects)
        let classified = localizedCount(progress.classifiedEntries)
        let allocated = localizedByteCount(progress.allocatedBytes)
        let logical = localizedByteCount(progress.logicalBytes)
        let path = progress.currentRelativePath.isEmpty
            ? "project root"
            : progress.currentRelativePath
        return "Scanned \(visited) file system objects; "
            + "classified \(classified) entries; "
            + "\(allocated) estimated on disk; "
            + "\(logical) logical; current item: \(path)."
    }

    static func validatedCleanupItems(
        _ items: [ProjectStorageCleanupExecutionSummary.Item]
    ) throws -> [UUID: ProjectStorageCleanupExecutionSummary.Item] {
        var validated:
            [UUID: ProjectStorageCleanupExecutionSummary.Item] = [:]
        for item in items {
            guard validated.updateValue(item, forKey: item.itemID) == nil else {
                throw CleanupSummaryError.duplicateItemIdentifier
            }
        }
        return validated
    }

    private func removableEntries(
        _ source: [ProjectStorageEntry],
        category: ProjectStorageEntry.Category
    ) -> [ProjectStorageEntry] {
        source
            .filter { $0.category == category }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath)
                    == .orderedAscending
            }
    }

    private func acceptScanAuthority(
        _ result: ProjectStorageScanResult
    ) -> Bool {
        guard revalidateBinding(),
              result.projectIdentity == projectIdentity else {
            markStale()
            return false
        }
        return true
    }

    private func applyEntries(_ entries: [ProjectStorageEntry]) {
        self.entries = entries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
        selectedEntryIDs = Set(
            entries
                .filter(\.classification.isRemovable)
                .map(\.id)
        )
    }

    private func saturatedTotal(
        _ entries: [ProjectStorageEntry],
        keyPath: KeyPath<ProjectStorageEntry, UInt64>
    ) -> UInt64 {
        entries.reduce(into: 0) { total, entry in
            let (next, overflow) = total.addingReportingOverflow(
                entry[keyPath: keyPath]
            )
            total = overflow ? .max : next
        }
    }

    private func markStale() {
        guard !isStale else { return }
        isStale = true
        state = .stale
        selectedEntryIDs.removeAll()
        statusMessage =
            "This window no longer owns the project used for this storage review."
        requestCancellation()
        notify()
    }

    private func notify() {
        onChange?()
    }
}
