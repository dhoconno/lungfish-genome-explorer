// AssemblyResultSurface.swift - The assembly result viewer as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Why an assembly did not open, in words a person can act on.
enum AssemblyResultOpenError: LocalizedError {
    case gone(fileName: String)
    case locked(fileName: String)

    var errorDescription: String? {
        switch self {
        case .gone(let fileName): "\(fileName) is no longer in this assembly's folder."
        case .locked(let fileName): "This Mac does not allow \(fileName) to be read."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .gone: "Check that the file is still in the project folder and that its drive is connected, then select it again."
        case .locked: "Check the file's permissions in Finder, then select it again."
        }
    }

    /// Asks the file system whether the contigs file is there and can be read. It opens nothing and reads no bases, so its
    /// cost on the main actor is one `stat`. A file that opens and does not parse still reaches `configure`'s own failure.
    static func check(_ result: AssemblyResult) throws {
        guard result.outcome != .completedWithNoContigs else { return }
        let files = FileManager.default
        let path = result.contigsPath.path
        guard files.fileExists(atPath: path) else { throw gone(fileName: result.contigsPath.lastPathComponent) }
        guard files.isReadableFile(atPath: path) else { throw locked(fileName: result.contigsPath.lastPathComponent) }
    }
}

/// The assembly result viewer as a ``ResultViewport``, one surface for five tool kinds.
///
/// Its input is the ``AssemblyResultViewController`` the App has made and wired, with the result it shows. The load checks
/// the contigs file and starts the controller's own read, and it does not suspend, so the host installs it before `show`
/// returns. The App registers one ``factory(for:)`` for each tool.
@MainActor
public final class AssemblyResultSurface: ResultViewport {
    /// What the display passes as `input`.
    public struct Input {
        public let controller: AssemblyResultViewController
        public let result: AssemblyResult

        public init(controller: AssemblyResultViewController, result: AssemblyResult) {
            self.controller = controller
            self.result = result
        }
    }

    public let surfaceKind: SurfaceKind

    /// The result viewer the host installs, once the load has adopted it.
    public private(set) var controller: AssemblyResultViewController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    init(tool: AssemblyTool) {
        surfaceKind = Self.kind(of: tool)
    }

    /// The factory the App registers for `tool`, which makes a new surface for each show.
    public static func factory(for tool: AssemblyTool) -> SurfaceRegistry.Factory {
        { AssemblyResultSurface(tool: tool) }
    }

    /// The surface kind of `tool`. A tool's raw value is its analysis id (`AnalysisToolRegistry.swift`).
    public static func kind(of tool: AssemblyTool) -> SurfaceKind {
        .analysis(AnalysisToolID(rawValue: tool.rawValue))
    }

    public var viewController: NSViewController { controller ?? unloaded }

    /// The summary strip sits at the top of the controller's own view, so it starts below the window's toolbar only when
    /// the view does. The old display pinned it to the safe area, and the host's edge pin would put it under the toolbar.
    public var pinsTopToSafeArea: Bool { true }

    /// A contig load that is still reading stops, so its failure raises no alert over what took this viewer's place. A
    /// BLAST search goes on, since only NCBI's answer or the person ends one, and its drawer's closures hold the controller.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        controller?.loadTask?.cancel()
    }

    /// Checks the contigs file, then adopts the controller. `configure` reads the file in its own task, under the guards
    /// lanes ASSEMBLY-PATH and REPLACED wrote.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        try AssemblyResultOpenError.check(request.result)
        _ = request.controller.view
        request.controller.configure(result: request.result)
        controller = request.controller
    }
}
