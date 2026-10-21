// ViralReconRunRequest+OutputFolder.swift - The results folder check of a Viral Recon run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ViralReconRunRequest {
    /// The one check that keeps a Viral Recon run out of a results folder an earlier run used, and the words for it
    /// (Phase 2.13 lane 13.21, UX words W1). The request's `init` and the `workflow run nf-core/viralrecon` leaf both
    /// call ``holdsFiles(_:fileManager:)``, so the app and the command line cannot disagree about which folder is
    /// refused. A run leaves its results in the folder it is given, so a folder that already holds files would end up
    /// with the earlier run's files beside the new run's own.
    public enum ResultsFolder {
        /// The title of the app's alert, which the failed row shows as its headline.
        public static let alertTitle = "Choose an empty results folder"

        /// True when `folder` is a directory that holds any entry. A hidden entry counts (MD26, Reading A), so a folder
        /// that Finder opened and left a `.DS_Store` in is refused too. A folder that does not exist yet and an empty
        /// one are not refused. Neither is a path that names a file or a folder that cannot be listed, which the run
        /// meets later exactly as it always did.
        public static func holdsFiles(_ folder: URL, fileManager: FileManager = .default) -> Bool {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
            return !entries.isEmpty
        }

        /// The app's alert text (W1). `folderName` is the folder's name as Finder shows it.
        public static func alertText(folderName: String) -> String {
            "\"\(folderName)\" already holds files, and a Viral Recon run would leave its results beside them. "
                + "Choose an empty folder or a new one."
        }

        /// The line the leaf prints (W1). `optionName` is the leaf's own option for the folder, `--results-dir`.
        public static func leafRefusal(optionName: String, path: String) -> String {
            "\(optionName) \(path) already holds files. Name an empty or new folder."
        }

        /// The alert title when `error` is the refusal of a folder that holds files, and nil for any other error.
        public static func title(for error: Error) -> String? {
            guard let validation = error as? ViralReconRunRequest.ValidationError,
                  case .resultsFolderHoldsFiles = validation else {
                return nil
            }
            return alertTitle
        }
    }
}

extension ViralReconRunRequest.ValidationError: LocalizedError {
    /// Only the results folder refusal has words so far. The other cases keep the description they always had.
    public var errorDescription: String? {
        switch self {
        case .resultsFolderHoldsFiles(let folder):
            return ViralReconRunRequest.ResultsFolder.alertText(folderName: folder.lastPathComponent)
        case .conflictingAdvancedParam, .emptySamples:
            return nil
        }
    }
}
