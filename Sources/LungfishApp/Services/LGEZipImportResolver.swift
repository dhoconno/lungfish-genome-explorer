// LGEZipImportResolver.swift - Resolves ZIP-compressed Lungfish objects before import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishWorkflow

struct LGEZipImportFailure: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case extractionFailed
        case noRecognizedLGEObject
        case multipleRecognizedLGEObjects
    }

    let sourceURL: URL
    let kind: Kind
    /// The failure in one sentence that names the archive, for the log and the drop's completion notice.
    let message: String
    /// Why the archive was not imported, in the words the failure sheet shows. It never names the archive, since the
    /// sheet's title does.
    let reason: String
}

extension LGEZipImportFailure {
    /// Why an extraction failed, in words about the archive and not about the tool.
    static func reason(forExtractionError error: Error) -> String {
        switch error {
        case GeneiousArchiveToolError.unsafeArchive:
            // `GeneiousArchiveTool.extract` reports only links here, the ones that
            // `SafeZipExtractor.verifySymbolicLinksStayInside` refuses.
            return "It holds a link to a file outside the archive, so Lungfish did not import it."
        case GeneiousArchiveToolError.unsafeMemberPath:
            return "It holds a file whose path leaves the archive's own folder, so Lungfish did not import it."
        case GeneiousArchiveToolError.unzipFailed(_, _, let stderr):
            let detail = stderr.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let tool = detail.isEmpty ? "" : " The unzip tool reported \u{201C}\(detail)\u{201D}."
            return "Lungfish could not unpack it, so nothing was imported. Check that the ZIP is complete, then drop it again." + tool
        default:
            return "Lungfish could not unpack it, so nothing was imported. \(error.localizedDescription)"
        }
    }

    /// The failures of a drop whose resolution threw. The throw ends the drop before anything is imported, so each
    /// dropped item failed.
    static func failures(ofThrown error: Error, sources: [URL]) -> [LGEZipImportFailure] {
        let reason = "Lungfish could not make a working folder in the project, so nothing was imported. "
            + "Check that you can write to the project folder, then try again. (\(error.localizedDescription))"
        return sources.map {
            LGEZipImportFailure(sourceURL: $0, kind: .extractionFailed, message: error.localizedDescription, reason: reason)
        }
    }
}

/// The one sheet that tells the person which archives were not imported and why.
struct LGEZipImportRefusal: Equatable, Sendable {
    let title: String
    let text: String

    /// One failure names its archive in the title and gives its reason as the text. Several share one sheet, which
    /// lists each archive with its reason. There is no refusal when nothing failed.
    init?(failures: [LGEZipImportFailure]) {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            title = "Could not import \(first.sourceURL.lastPathComponent)"
            text = first.reason
        } else {
            title = "Could not import \(failures.count) items"
            text = failures.map { "\($0.sourceURL.lastPathComponent)\n\($0.reason)" }.joined(separator: "\n\n")
        }
    }
}

final class LGEZipImportBatch: @unchecked Sendable {
    let sourceURLs: [URL]
    let failures: [LGEZipImportFailure]

    private let cleanupURLs: [URL]
    private let removesEmptyTempFolder: Bool
    private let fileManager: FileManager
    private var didCleanup = false

    /// `removesEmptyTempFolder` is true when the project had no `.tmp` folder before this batch, so the folder the
    /// batch made goes when it is left empty and a folder that was there before stays.
    init(
        sourceURLs: [URL],
        failures: [LGEZipImportFailure],
        cleanupURLs: [URL],
        removesEmptyTempFolder: Bool = false,
        fileManager: FileManager = .default
    ) {
        self.sourceURLs = sourceURLs
        self.failures = failures
        self.cleanupURLs = cleanupURLs
        self.removesEmptyTempFolder = removesEmptyTempFolder
        self.fileManager = fileManager
    }

    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        for url in cleanupURLs {
            try? fileManager.removeItem(at: url)
        }
        // The project's `.tmp` folder goes too when this batch made it and leaves it empty, so a refused ZIP leaves
        // the project as it was. `rmdir` removes an empty folder and no other, so it never takes the folder of an
        // operation that started meanwhile.
        if removesEmptyTempFolder {
            for parent in Set(cleanupURLs.map { $0.deletingLastPathComponent() }) where Self.isProjectTempFolder(parent) {
                _ = rmdir(parent.path)
            }
        }
    }

    private static func isProjectTempFolder(_ url: URL) -> Bool {
        url.lastPathComponent == ProjectTempDirectory.tempRoot(for: url.deletingLastPathComponent()).lastPathComponent
    }

    deinit {
        cleanup()
    }
}

struct LGEZipImportResolver {
    private let fileManager: FileManager
    private let archiveTool: GeneiousArchiveTool

    init(
        fileManager: FileManager = .default,
        archiveTool: GeneiousArchiveTool = GeneiousArchiveTool()
    ) {
        self.fileManager = fileManager
        self.archiveTool = archiveTool
    }

    func resolve(urls: [URL], projectURL: URL?) throws -> LGEZipImportBatch {
        var resolvedURLs: [URL] = []
        var failures: [LGEZipImportFailure] = []
        var cleanupURLs: [URL] = []
        // The batch removes the project's `.tmp` folder only when it makes it, so one that was there stays.
        let madeTempFolder = projectURL.map { !fileManager.fileExists(atPath: ProjectTempDirectory.tempRoot(for: $0).path) } ?? false

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.pathExtension.lowercased() == "zip" else {
                resolvedURLs.append(standardizedURL)
                continue
            }

            let tempRoot = try ProjectTempDirectory.create(prefix: "sidebar-zip-import-", in: projectURL)
            cleanupURLs.append(tempRoot)

            do {
                try archiveTool.extract(archiveURL: standardizedURL, to: tempRoot)
                let candidates = try recognizedLGEObjects(in: tempRoot)
                switch candidates.count {
                case 1:
                    resolvedURLs.append(candidates[0])
                case 0:
                    failures.append(
                        LGEZipImportFailure(
                            sourceURL: standardizedURL,
                            kind: .noRecognizedLGEObject,
                            message: "\(standardizedURL.lastPathComponent) does not contain a recognized Lungfish object.",
                            reason: "It holds no Lungfish bundle, so Lungfish did not import it. Drop a ZIP that holds one bundle."
                        )
                    )
                default:
                    failures.append(
                        LGEZipImportFailure(
                            sourceURL: standardizedURL,
                            kind: .multipleRecognizedLGEObjects,
                            message: "\(standardizedURL.lastPathComponent) contains multiple Lungfish objects; import one archive per object.",
                            reason: "It holds more than one Lungfish bundle, so Lungfish did not import it. Drop one ZIP for each bundle."
                        )
                    )
                }
            } catch {
                failures.append(
                    LGEZipImportFailure(
                        sourceURL: standardizedURL,
                        kind: .extractionFailed,
                        message: error.localizedDescription,
                        reason: LGEZipImportFailure.reason(forExtractionError: error)
                    )
                )
            }
        }

        return LGEZipImportBatch(
            sourceURLs: resolvedURLs,
            failures: failures,
            cleanupURLs: cleanupURLs,
            removesEmptyTempFolder: madeTempFolder,
            fileManager: fileManager
        )
    }

    /// Resolves on a background thread. `resolve` unzips every selected ZIP through
    /// ``GeneiousArchiveTool``, which waits in `ToolProcess.runBlocking`, and that call must not
    /// run on the main thread, since the run loop would stop for the whole extraction.
    func resolveOffMainActor(urls: [URL], projectURL: URL?) async throws -> LGEZipImportBatch {
        // The detached task receives the archive tool (Sendable) and builds its own resolver.
        let archiveTool = self.archiveTool
        return try await Task.detached(priority: .userInitiated) {
            try LGEZipImportResolver(archiveTool: archiveTool).resolve(urls: urls, projectURL: projectURL)
        }.value
    }

    /// Tells the person which of the dropped archives were not imported and why, in one sheet on `window`. The
    /// failures of a batch and the failures of a resolution that threw reach it the same way, and nothing shows when
    /// there are none. `presenter` defaults to the seam's, read where the call is made, so a caller whose task does
    /// not inherit a test's binding reads the seam first and passes it in.
    @MainActor
    static func presentRefusal(
        of failures: [LGEZipImportFailure],
        on window: NSWindow?,
        using presenter: any LGEZipImportFailurePresenting = LGEZipImportFailureSeam.presenter
    ) {
        guard let refusal = LGEZipImportRefusal(failures: failures) else { return }
        presenter.present(title: refusal.title, message: refusal.text, on: window)
    }

    private func recognizedLGEObjects(in rootURL: URL) throws -> [URL] {
        var candidates: [URL] = []
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            guard SidebarProjectScanner.isNativePackage(url) else {
                continue
            }

            candidates.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }

        return candidates.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

}

/// Shows the person why a dropped archive was not imported.
///
/// The live presenter puts a sheet on the window it is given and shows an application-modal alert with none. A
/// test binds a recording presenter through ``LGEZipImportFailureSeam``, because an application-modal alert in
/// a unit test waits for a click that never comes.
protocol LGEZipImportFailurePresenting: Sendable {
    /// Shows `title` over `message` on `window`, or application-modal when `window` is nil.
    @MainActor func present(title: String, message: String, on window: NSWindow?)
}

/// The presenter the app runs with.
///
/// The application-modal alert goes through `NSApp.presentError`, as ``LiveNoProjectAlertPresenter`` does, because
/// the project rules forbid calling `runModal` (agents/process/PROJECT-LEAD-AGENT.md).
struct LiveLGEZipImportFailurePresenter: LGEZipImportFailurePresenting {
    @MainActor func present(title: String, message: String, on window: NSWindow?) {
        if let window {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.applyLungfishBranding()
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            NSApp.presentError(Refusal(title: title, message: message))
        }
    }

    /// The refusal as an error, which AppKit shows as an application-modal alert holding the title in bold over
    /// the message.
    private struct Refusal: LocalizedError {
        let title: String
        let message: String

        var errorDescription: String? { title }
        var recoverySuggestion: String? { message }
    }
}

/// The presenter the dropped-archive refusal reads.
///
/// The default is the live presenter. Only a test binds another, with `$presenter.withValue`, to record what the
/// refusal hands over. The presenter is task-local, so nothing can assign it, and the drop reads it on the main
/// actor in the task that follows the drop. File > Import Files... reads it in the call that starts the import, as
/// `ImportFilesOutcomeSeam` does, because its import continues after a run-loop hop that drops a task-local binding.
enum LGEZipImportFailureSeam {
    @TaskLocal static var presenter: any LGEZipImportFailurePresenting = LiveLGEZipImportFailurePresenter()
}
