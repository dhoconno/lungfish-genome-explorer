// FASTACollectionSurface.swift - The FASTA collection browser as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

/// Why a collection did not open. A file the sequences came from has gone or cannot be read, so nobody could check or
/// run what the list would show.
enum FASTACollectionOpenError: LocalizedError, Equatable {
    case fileGone(name: String)
    case fileLocked(name: String)

    var errorDescription: String? {
        switch self {
        case .fileGone(let name): return "\(name) is no longer where it was opened from."
        case .fileLocked(let name): return "This Mac does not allow \(name) to be read."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileGone: return "Check that the file is still in the project folder and that its drive is connected, then select it again."
        case .fileLocked: return "Check the file's permissions in Finder, then select it again."
        }
    }
}

/// The FASTA collection browser as a ``ResultViewport``. It lives in the App because its controller does.
///
/// The display builds the controller and wires its callbacks. ``load(input:token:)`` configures it and does not suspend, so
/// the host installs the list before `show` returns. The way back from one sequence shows the same controller again with no
/// ``Contents``, so the person's selection, sort, filter and scroll place stay as they were. The surface has nothing to stop
/// on its way out: a search the list has running goes on, since only NCBI's answer or the person ends one.
@MainActor
final class FASTACollectionSurface: ResultViewport {
    /// What the list shows, and the files it was read from. The sequences are in memory by now, so `load` asks of each
    /// file only whether it is there and readable, the cost of one `stat`, and never reads it on the main actor.
    struct Contents {
        let sequences: [LungfishCore.Sequence]
        let annotations: [SequenceAnnotation]
        let sourceNames: [UUID: String]
        let sourceFiles: [URL]
    }

    /// What the display passes as `input`.
    struct Input {
        /// The list to show. It reaches ``controller`` only when the load succeeds.
        let controller: FASTACollectionViewController
        /// Nil on the way back, when the list already shows what it showed.
        let contents: Contents?
    }

    /// The list the host installs, once the load has adopted it.
    private(set) var controller: FASTACollectionViewController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }

    var surfaceKind: SurfaceKind { .view(.fastaCollection) }

    /// The summary bar sits at the top of the list's own view, so it starts below the window's toolbar. The old display
    /// pinned the list to the safe area, and the host's edge pin would put it under the toolbar.
    var pinsTopToSafeArea: Bool { true }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        if let contents = request.contents {
            try Self.checkFiles(contents.sourceFiles)
            // The host loads the list's view only when it installs it, after this load. The table must sit in its scroll
            // view before it learns its rows, since a table in none takes its whole height as visible and builds a row
            // view and five cells for every record, which Auto Layout never finished solving on a large file (W-34).
            request.controller.loadViewIfNeeded()
            request.controller.configure(sequences: contents.sequences, annotations: contents.annotations, sourceNames: contents.sourceNames)
        }
        controller = request.controller
    }

    private static func checkFiles(_ files: [URL]) throws {
        let manager = FileManager.default
        for file in files {
            guard manager.fileExists(atPath: file.path) else {
                throw FASTACollectionOpenError.fileGone(name: file.lastPathComponent)
            }
            guard manager.isReadableFile(atPath: file.path) else {
                throw FASTACollectionOpenError.fileLocked(name: file.lastPathComponent)
            }
        }
    }
}
