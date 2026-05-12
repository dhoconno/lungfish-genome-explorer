# Same Project Multi-Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make opening the same `.lungfish` project in multiple app windows a supported, testable workflow with independent window state, project-wide refresh, correct operation routing, and enforced scientific provenance expectations.

**Architecture:** Add window-owned project sessions and an app-owned project session registry. Route UI state by `WindowStateScope`, route project refresh by canonical project URL, and route operation completion by both project URL and origin window scope. Keep `DocumentManager.shared` temporarily as a compatibility facade while project/window state moves into sessions.

**Tech Stack:** Swift 6.2+, AppKit, LungfishApp, LungfishCore `ProjectFile`, FSEvents through existing `FileSystemWatcher`, XCTest, XCUITest.

---

## File Structure

- Create `Sources/LungfishApp/StateManagement/ProjectSession.swift`
  Window-owned project/document state and project open/create/load behavior.
- Create `Sources/LungfishApp/StateManagement/ProjectSessionRegistry.swift`
  App-owned registry for sessions, same-project numbering, frontmost session, duplicate-open choices, and read-only lock state.
- Modify `Sources/LungfishApp/App/DocumentManager.swift`
  Extract reusable document/project loading helpers and keep singleton compatibility during migration.
- Modify `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
  Store a `ProjectSession` per window and pass it to the split view controller.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  Use session state instead of singleton project/document state.
- Modify `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
  Register for project refresh fanout and preserve per-window UI state.
- Modify `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  Prefer the parent session/project URL over `DocumentManager.shared.activeProject`.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` and focused viewer extensions touched by tests
  Scope UI-affecting notifications and project lookups.
- Modify `Sources/LungfishApp/App/AppDelegate.swift`
  Replace global `mainWindowController` routing with sender/key-window/session routing.
- Modify `Sources/LungfishApp/App/MainMenu.swift`
  Add `Window > New Window for Current Project` and duplicate-window title support.
- Modify `Sources/LungfishApp/Services/DownloadCenter.swift`
  Add operation routing metadata to `OperationCenter` items and bundle-ready delivery.
- Create `Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift`
  One watcher per project URL with fanout to registered windows.
- Add tests:
  `Tests/LungfishAppTests/ProjectSessionTests.swift`,
  `Tests/LungfishAppTests/ProjectSessionRegistryTests.swift`,
  `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`,
  `Tests/LungfishAppTests/NotificationProjectScopeTests.swift`,
  `Tests/LungfishAppTests/OperationRoutingTests.swift`,
  `Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorTests.swift`,
  and one XCUITest in `Tests/LungfishXCUITests/ProjectLifecycleXCUITests.swift`.

---

### Task 1: Add Window-Owned Project Sessions

**Files:**
- Create: `Sources/LungfishApp/StateManagement/ProjectSession.swift`
- Modify: `Sources/LungfishApp/App/DocumentManager.swift`
- Test: `Tests/LungfishAppTests/ProjectSessionTests.swift`

- [ ] **Step 1: Write the failing independence tests**

```swift
import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class ProjectSessionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testTwoSessionsCanOpenSameProjectWithIndependentActiveDocument() throws {
        let projectURL = tempRoot.appendingPathComponent("Shared.lungfish", isDirectory: true)
        let project = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
        let seqA = try Sequence(name: "alpha", alphabet: .dna, bases: "ATCG")
        let seqB = try Sequence(name: "beta", alphabet: .dna, bases: "GGCC")
        _ = try project.addSequence(seqA)
        _ = try project.addSequence(seqB)
        try project.save()

        let first = ProjectSession(windowStateScope: WindowStateScope())
        let second = ProjectSession(windowStateScope: WindowStateScope())

        try first.openProject(at: projectURL)
        try second.openProject(at: projectURL)

        XCTAssertEqual(first.projectURL?.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(second.projectURL?.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(first.documents.count, 2)
        XCTAssertEqual(second.documents.count, 2)

        first.setActiveDocument(first.documents[0])
        second.setActiveDocument(second.documents[1])

        XCTAssertEqual(first.activeDocument?.name, "alpha")
        XCTAssertEqual(second.activeDocument?.name, "beta")
    }
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter ProjectSessionTests/testTwoSessionsCanOpenSameProjectWithIndependentActiveDocument`

Expected: FAIL because `ProjectSession` does not exist.

- [ ] **Step 3: Extract reusable project document loading from `DocumentManager`**

Add a package-visible helper in `DocumentManager.swift` so `DocumentManager` and `ProjectSession` use the same sequence-to-document conversion:

```swift
@MainActor
enum ProjectDocumentLoader {
    static func loadSequences(from project: ProjectFile) throws -> [LoadedDocument] {
        let sequenceSummaries = try project.listSequences()
        var projectDocuments: [LoadedDocument] = []

        for summary in sequenceSummaries {
            let content = try project.getSequenceContent(id: summary.id)
            let alphabet: SequenceAlphabet = summary.alphabet == "dna" ? .dna :
                summary.alphabet == "rna" ? .rna : .protein
            let sequence = try Sequence(
                id: summary.id,
                name: summary.name,
                alphabet: alphabet,
                bases: content
            )

            let document = LoadedDocument(
                url: project.url.appendingPathComponent(summary.name),
                type: .lungfishProject
            )
            document.sequences = [sequence]
            document.annotations = try project.getAnnotations(for: summary.id).map { stored in
                SequenceAnnotation(
                    id: stored.id,
                    type: AnnotationType(rawValue: stored.type) ?? .region,
                    name: stored.name,
                    intervals: [AnnotationInterval(start: stored.startPosition, end: stored.endPosition)],
                    strand: stored.strand == "+" ? .forward : (stored.strand == "-" ? .reverse : .unknown),
                    qualifiers: (stored.qualifiers ?? [:]).mapValues { AnnotationQualifier($0) }
                )
            }
            projectDocuments.append(document)
        }

        return projectDocuments
    }
}
```

Then replace `DocumentManager.loadSequencesFromProject(_:)` internals with:

```swift
private func loadSequencesFromProject(_ project: ProjectFile) throws -> [LoadedDocument] {
    try ProjectDocumentLoader.loadSequences(from: project)
}
```

- [ ] **Step 4: Implement `ProjectSession`**

```swift
import Foundation
import LungfishCore

@MainActor
public final class ProjectSession: Identifiable {
    public let id: UUID
    public let windowStateScope: WindowStateScope
    public private(set) var projectURL: URL?
    public private(set) var project: ProjectFile?
    public private(set) var openWarningState: ProjectOpenWarningState = .unlocked(projectURL: nil)
    public private(set) var documents: [LoadedDocument] = []
    public private(set) var activeDocument: LoadedDocument?
    public private(set) var workingDirectoryURL: URL?

    public init(id: UUID = UUID(), windowStateScope: WindowStateScope = WindowStateScope()) {
        self.id = id
        self.windowStateScope = windowStateScope
    }

    @discardableResult
    public func openProject(at url: URL) throws -> ProjectFile {
        let standardizedURL = url.standardizedFileURL
        let warning = ProjectOpenWarningState.evaluate(projectURL: standardizedURL)
        let openedProject = try ProjectFile.open(at: standardizedURL)
        let loadedDocuments = try ProjectDocumentLoader.loadSequences(from: openedProject)

        projectURL = openedProject.url.standardizedFileURL
        workingDirectoryURL = openedProject.url.standardizedFileURL
        project = openedProject
        openWarningState = warning
        documents = loadedDocuments
        activeDocument = loadedDocuments.first

        return openedProject
    }

    @discardableResult
    public func createProject(at url: URL, name: String, description: String? = nil, author: String? = nil) throws -> ProjectFile {
        let createdProject = try ProjectFile.create(at: url, name: name, description: description, author: author)
        _ = try? PrimerSchemesFolder.ensureFolder(in: createdProject.url)
        projectURL = createdProject.url.standardizedFileURL
        workingDirectoryURL = createdProject.url.standardizedFileURL
        project = createdProject
        openWarningState = .unlocked(projectURL: createdProject.url)
        documents = []
        activeDocument = nil
        return createdProject
    }

    public func setActiveDocument(_ document: LoadedDocument?) {
        activeDocument = document
    }

    public func closeProject() {
        projectURL = nil
        workingDirectoryURL = nil
        project = nil
        openWarningState = .unlocked(projectURL: nil)
        documents = []
        activeDocument = nil
    }
}
```

- [ ] **Step 5: Run the session tests**

Run: `swift test --filter ProjectSessionTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/StateManagement/ProjectSession.swift Sources/LungfishApp/App/DocumentManager.swift Tests/LungfishAppTests/ProjectSessionTests.swift
git commit -m "refactor: add window project sessions"
```

---

### Task 2: Add the Project Session Registry

**Files:**
- Create: `Sources/LungfishApp/StateManagement/ProjectSessionRegistry.swift`
- Test: `Tests/LungfishAppTests/ProjectSessionRegistryTests.swift`

- [ ] **Step 1: Write registry tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectSessionRegistryTests: XCTestCase {
    func testRegistersMultipleSessionsForSameCanonicalProjectURL() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()

        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url.standardizedFileURL)

        XCTAssertEqual(registry.sessions(forProjectURL: url).count, 2)
        XCTAssertEqual(registry.windowNumber(for: first), 1)
        XCTAssertEqual(registry.windowNumber(for: second), 2)
    }

    func testUnregisterRemovesOnlyThatSession() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()
        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url)

        registry.unregister(first)

        XCTAssertEqual(registry.sessions(forProjectURL: url).map(\.id), [second.id])
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run: `swift test --filter ProjectSessionRegistryTests`

Expected: FAIL because `ProjectSessionRegistry` does not exist.

- [ ] **Step 3: Implement the registry**

```swift
import Foundation

@MainActor
public final class ProjectSessionRegistry {
    private var sessionsByID: [UUID: ProjectSession] = [:]
    private var projectURLsBySessionID: [UUID: URL] = [:]
    private var frontmostSessionID: UUID?

    public init() {}

    public func register(_ session: ProjectSession, projectURL: URL?) {
        sessionsByID[session.id] = session
        if let projectURL {
            projectURLsBySessionID[session.id] = Self.canonicalProjectURL(projectURL)
        }
    }

    public func unregister(_ session: ProjectSession) {
        sessionsByID.removeValue(forKey: session.id)
        projectURLsBySessionID.removeValue(forKey: session.id)
        if frontmostSessionID == session.id {
            frontmostSessionID = nil
        }
    }

    public func markFrontmost(_ session: ProjectSession) {
        sessionsByID[session.id] = session
        frontmostSessionID = session.id
    }

    public var frontmostSession: ProjectSession? {
        frontmostSessionID.flatMap { sessionsByID[$0] }
    }

    public func sessions(forProjectURL projectURL: URL) -> [ProjectSession] {
        let canonical = Self.canonicalProjectURL(projectURL)
        return sessionsByID.values
            .filter { projectURLsBySessionID[$0.id] == canonical }
            .sorted { windowNumber(for: $0) < windowNumber(for: $1) }
    }

    public func windowNumber(for session: ProjectSession) -> Int {
        guard let projectURL = projectURLsBySessionID[session.id] else { return 1 }
        let peerIDs = sessionsByID.values
            .filter { projectURLsBySessionID[$0.id] == projectURL }
            .map(\.id.uuidString)
            .sorted()
        guard let index = peerIDs.firstIndex(of: session.id.uuidString) else { return 1 }
        return index + 1
    }

    public static func canonicalProjectURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
```

- [ ] **Step 4: Run registry tests**

Run: `swift test --filter ProjectSessionRegistryTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/StateManagement/ProjectSessionRegistry.swift Tests/LungfishAppTests/ProjectSessionRegistryTests.swift
git commit -m "feat: track project sessions by window"
```

---

### Task 3: Wire Sessions Into Main Windows

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Write a window/session wiring test**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class MainWindowSessionRoutingTests: XCTestCase {
    func testMainWindowControllerKeepsAssignedProjectSession() {
        let session = ProjectSession()
        let controller = MainWindowController(projectSession: session)

        XCTAssertTrue(controller.projectSession === session)
        XCTAssertTrue(controller.mainSplitViewController.projectSession === session)
    }
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter MainWindowSessionRoutingTests/testMainWindowControllerKeepsAssignedProjectSession`

Expected: FAIL because `MainWindowController(projectSession:)` does not exist.

- [ ] **Step 3: Add session storage to `MainWindowController`**

Change the controller initializer shape to:

```swift
public private(set) var projectSession: ProjectSession

public convenience init(projectSession: ProjectSession = ProjectSession()) {
    let window = Self.createMainWindow()
    self.init(window: window, projectSession: projectSession)
    configureWindow()
}

public init(window: NSWindow?, projectSession: ProjectSession = ProjectSession()) {
    self.projectSession = projectSession
    super.init(window: window)
}

@available(*, unavailable)
required init?(coder: NSCoder) {
    fatalError("MainWindowController does not support storyboard initialization")
}
```

Then change `configureWindow()` so it creates:

```swift
mainSplitViewController = MainSplitViewController(projectSession: projectSession)
```

- [ ] **Step 4: Add session storage to `MainSplitViewController`**

Add:

```swift
public private(set) var projectSession: ProjectSession

public init(projectSession: ProjectSession = ProjectSession()) {
    self.projectSession = projectSession
    super.init(nibName: nil, bundle: nil)
}

@available(*, unavailable)
required init?(coder: NSCoder) {
    fatalError("MainSplitViewController does not support storyboard initialization")
}
```

In `configureChildControllers()`, assign:

```swift
sidebarController.windowStateScope = projectSession.windowStateScope
inspectorController.windowStateScope = projectSession.windowStateScope
```

- [ ] **Step 5: Update `AppDelegate.createAndShowMainWindow()`**

Create sessions through the registry:

```swift
private let projectSessionRegistry = ProjectSessionRegistry()

@discardableResult
private func createAndShowMainWindow(projectSession: ProjectSession = ProjectSession()) -> MainWindowController {
    let controller = MainWindowController(projectSession: projectSession)
    controller.showWindow(nil)
    mainWindowController = controller
    projectSessionRegistry.register(projectSession, projectURL: projectSession.projectURL)
    if !mainWindowControllers.contains(where: { $0 === controller }) {
        mainWindowControllers.append(controller)
    }
    return controller
}
```

- [ ] **Step 6: Run routing tests**

Run: `swift test --filter MainWindowSessionRoutingTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainWindowController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "refactor: bind project sessions to windows"
```

---

### Task 4: Replace Global Project Open Flow With Session Apply Flow

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/App/DocumentManager.swift`
- Test: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Add a test for opening the same project in two sessions**

```swift
func testOpeningSameProjectInTwoControllersDoesNotShareActiveDocument() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("SameProjectWindows-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
    let project = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
    _ = try project.addSequence(try Sequence(name: "left", alphabet: .dna, bases: "AAAA"))
    _ = try project.addSequence(try Sequence(name: "right", alphabet: .dna, bases: "CCCC"))
    try project.save()

    let first = MainWindowController(projectSession: ProjectSession())
    let second = MainWindowController(projectSession: ProjectSession())

    try first.projectSession.openProject(at: projectURL)
    try second.projectSession.openProject(at: projectURL)
    first.projectSession.setActiveDocument(first.projectSession.documents[0])
    second.projectSession.setActiveDocument(second.projectSession.documents[1])

    XCTAssertEqual(first.projectSession.activeDocument?.name, "left")
    XCTAssertEqual(second.projectSession.activeDocument?.name, "right")
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter MainWindowSessionRoutingTests/testOpeningSameProjectInTwoControllersDoesNotShareActiveDocument`

Expected: PASS after Task 3. If it fails because `DocumentManager.shared.createProject` leaves global state dirty, clear the singleton only in test teardown using `DocumentManager.shared.closeActiveProject()`.

- [ ] **Step 3: Change `AppDelegate.openProject(_:in:)`**

Replace the `DocumentManager.shared.openProject(at:)` call with:

```swift
let project = try controller.projectSession.openProject(at: projectURL)
projectSessionRegistry.register(controller.projectSession, projectURL: project.url)
controller.mainSplitViewController?.applyProjectSessionState()
RecentProjectsManager.shared.addRecentProject(url: project.url, name: project.name)
```

- [ ] **Step 4: Add `MainSplitViewController.applyProjectSessionState()`**

```swift
public func applyProjectSessionState() {
    guard let project = projectSession.project else {
        sidebarController.closeProject()
        viewerController?.showNoSequenceSelected()
        return
    }

    let projectName = project.url.deletingPathExtension().lastPathComponent
    view.window?.title = "\(projectName) - Lungfish Genome Explorer"
    sidebarController.openProject(at: project.url)

    if let firstDoc = projectSession.documents.first {
        viewerController?.hideProgress()
        viewerController?.displayDocument(firstDoc)
    } else {
        viewerController?.showNoSequenceSelected()
    }
}
```

- [ ] **Step 5: Stop relying on `DocumentManager.projectOpenedNotification` for window setup**

Remove the `DocumentManager.projectOpenedNotification` observer from `MainSplitViewController.configureNotifications()` and delete `handleProjectOpened(_:)` after all callers use `applyProjectSessionState()`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
swift test --filter MainWindowSessionRoutingTests
swift test --filter ProjectLifecycleXCUITests/testUITestProjectPathLaunchOpensProjectWithoutWelcome
```

Expected: unit tests pass; XCUITest command may require the app test environment. If the XCUITest cannot run locally, record the exact environment error.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/App/DocumentManager.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "refactor: open projects through window sessions"
```

---

### Task 5: Route Menus and App Actions to the Sender Window

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Add target helper tests**

```swift
func testTargetProjectSessionUsesSenderWindowController() {
    let delegate = AppDelegate()
    let left = MainWindowController(projectSession: ProjectSession())
    let right = MainWindowController(projectSession: ProjectSession())
    delegate.testingRegisterMainWindowController(left)
    delegate.testingRegisterMainWindowController(right)

    let sender = NSButton()
    left.window?.contentView?.addSubview(sender)

    XCTAssertTrue(delegate.testingTargetProjectSession(sender: sender) === left.projectSession)
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter MainWindowSessionRoutingTests/testTargetProjectSessionUsesSenderWindowController`

Expected: FAIL because testing hooks and target helpers do not exist.

- [ ] **Step 3: Add target helpers**

Add non-private internal helpers guarded by regular access control so tests can call them with `@testable`:

```swift
func targetMainWindowController(sender: Any?) -> MainWindowController? {
    if let responder = sender as? NSResponder {
        var current: NSResponder? = responder
        while let node = current {
            if let view = node as? NSView,
               let controller = view.window?.windowController as? MainWindowController {
                return controller
            }
            if let window = node as? NSWindow,
               let controller = window.windowController as? MainWindowController {
                return controller
            }
            current = node.nextResponder
        }
    }

    if let keyController = NSApp.keyWindow?.windowController as? MainWindowController {
        return keyController
    }
    return mainWindowController
}

func targetProjectSession(sender: Any?) -> ProjectSession? {
    targetMainWindowController(sender: sender)?.projectSession
}
```

- [ ] **Step 4: Migrate high-risk actions first**

Replace direct `mainWindowController` reads in these paths with `targetMainWindowController(sender:)` or `targetProjectSession(sender:)`:

- `openDocument(at:)`
- `newDocument(_:)`
- `openProjectFolder(_:)`
- `openRecentProjectFromMenu(_:)`
- import center and FASTQ operation launch paths
- operations panel reveal/selection paths

Use this pattern:

```swift
guard let controller = targetMainWindowController(sender: sender) else { return }
let session = controller.projectSession
let projectURL = controller.mainSplitViewController?.sidebarController.currentProjectURL ?? session.projectURL
```

- [ ] **Step 5: Add a migration audit command to the commit message body**

Run:

```bash
rg -n "mainWindowController\\?|DocumentManager\\.shared\\.activeProject|DocumentManager\\.shared\\.activeDocument" Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/Views
```

Expected: remaining matches are either UI-global windows such as About/Settings/Help, or have an inline reason in code because no project session is involved.

- [ ] **Step 6: Run focused tests**

Run: `swift test --filter MainWindowSessionRoutingTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "refactor: route app actions through target windows"
```

---

### Task 6: Formalize Window and Project Notification Scoping

**Files:**
- Modify: `Sources/LungfishApp/StateManagement/WindowStateScope.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Test: `Tests/LungfishAppTests/NotificationProjectScopeTests.swift`

- [ ] **Step 1: Write notification scoping tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class NotificationProjectScopeTests: XCTestCase {
    func testWindowPrivateNotificationMatchesOnlySameScope() {
        let left = WindowStateScope()
        let right = WindowStateScope()
        let notification = Notification(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: left]
        )

        XCTAssertTrue(NotificationScopeMatcher.accepts(notification, windowStateScope: left, projectURL: nil))
        XCTAssertFalse(NotificationScopeMatcher.accepts(notification, windowStateScope: right, projectURL: nil))
    }

    func testProjectRefreshNotificationMatchesSameCanonicalProject() {
        let window = WindowStateScope()
        let project = URL(fileURLWithPath: "/tmp/A.lungfish", isDirectory: true)
        let notification = Notification(
            name: .projectContentsChanged,
            object: nil,
            userInfo: [NotificationUserInfoKey.projectURL: project.standardizedFileURL]
        )

        XCTAssertTrue(NotificationScopeMatcher.accepts(notification, windowStateScope: window, projectURL: project))
        XCTAssertFalse(NotificationScopeMatcher.accepts(notification, windowStateScope: window, projectURL: URL(fileURLWithPath: "/tmp/B.lungfish", isDirectory: true)))
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run: `swift test --filter NotificationProjectScopeTests`

Expected: FAIL because `.projectContentsChanged`, `NotificationScopeMatcher`, and keys do not exist.

- [ ] **Step 3: Add scope matcher and keys**

Extend the notification key area:

```swift
public extension Notification.Name {
    static let projectContentsChanged = Notification.Name("ProjectContentsChanged")
}

public extension NotificationUserInfoKey {
    static let projectURL = "projectURL"
    static let projectSessionID = "projectSessionID"
    static let originWindowStateScope = "originWindowStateScope"
}

enum NotificationScopeMatcher {
    static func accepts(_ notification: Notification, windowStateScope: WindowStateScope, projectURL: URL?) -> Bool {
        if let scope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope {
            return scope == windowStateScope
        }

        if let notificationProjectURL = notification.userInfo?[NotificationUserInfoKey.projectURL] as? URL {
            guard let projectURL else { return false }
            return ProjectSessionRegistry.canonicalProjectURL(notificationProjectURL) == ProjectSessionRegistry.canonicalProjectURL(projectURL)
        }

        return true
    }
}
```

- [ ] **Step 4: Scope known unscoped UI-affecting posts**

Add `windowStateScope` to posts that affect inspector visibility, bundle loaded behavior, viewport content mode, chromosome inspector requests, and sidebar navigation. Use the existing scoped sidebar selection pattern in `SidebarViewController.sidebarSelectionUserInfo(items:)` as the model.

- [ ] **Step 5: Update observers to use `NotificationScopeMatcher`**

In `MainSplitViewController`, `SidebarViewController`, and `InspectorViewController`, replace local scope helper duplication with:

```swift
guard NotificationScopeMatcher.accepts(
    notification,
    windowStateScope: projectSession.windowStateScope,
    projectURL: projectSession.projectURL
) else { return }
```

- [ ] **Step 6: Audit unscoped notifications**

Run:

```bash
rg -n "NotificationCenter\\.default\\.post" Sources/LungfishApp/Views Sources/LungfishApp/App | rg -v "windowStateScope|projectURL|appSettingsChanged|databaseStorageLocationChanged|variantColorThemeDidChange"
```

Expected: remaining unscoped notifications are app-global settings, non-project UI, or deliberately global operations events.

- [ ] **Step 7: Run tests**

Run: `swift test --filter NotificationProjectScopeTests`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/StateManagement/WindowStateScope.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift Tests/LungfishAppTests/NotificationProjectScopeTests.swift
git commit -m "fix: scope project window notifications"
```

---

### Task 7: Add Operation Routing Metadata

**Files:**
- Modify: `Sources/LungfishApp/Services/DownloadCenter.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: focused operation presenters touched by tests
- Test: `Tests/LungfishAppTests/OperationRoutingTests.swift`
- Test: extend `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`

- [ ] **Step 1: Write operation route tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class OperationRoutingTests: XCTestCase {
    func testBundleReadyDeliveryCarriesProjectAndOriginWindow() {
        let projectURL = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let scope = WindowStateScope()
        let route = OperationRoute(projectURL: projectURL, originWindowStateScope: scope, autoSelectOutputs: true)
        let bundle = URL(fileURLWithPath: "/tmp/Shared.lungfish/Outputs/A.lungfishfastq", isDirectory: true)

        let delivery = OperationBundleReadyDelivery(bundleURLs: [bundle], route: route)

        XCTAssertEqual(delivery.route?.projectURL.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(delivery.route?.originWindowStateScope, scope)
        XCTAssertEqual(delivery.bundleURLs, [bundle])
    }
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter OperationRoutingTests/testBundleReadyDeliveryCarriesProjectAndOriginWindow`

Expected: FAIL because route types do not exist.

- [ ] **Step 3: Add route types**

```swift
public struct OperationRoute: Hashable, Sendable {
    public let projectURL: URL
    public let originWindowStateScope: WindowStateScope
    public let autoSelectOutputs: Bool

    public init(projectURL: URL, originWindowStateScope: WindowStateScope, autoSelectOutputs: Bool = true) {
        self.projectURL = projectURL.standardizedFileURL
        self.originWindowStateScope = originWindowStateScope
        self.autoSelectOutputs = autoSelectOutputs
    }
}

public struct OperationBundleReadyDelivery: Sendable {
    public let bundleURLs: [URL]
    public let route: OperationRoute?
}
```

- [ ] **Step 4: Store route on operation items**

Extend `OperationCenter.Item` with:

```swift
public let route: OperationRoute?
```

Extend `OperationCenter.start(...)` with a defaulted `route: OperationRoute? = nil` parameter and thread it into the item initializer.

- [ ] **Step 5: Replace raw bundle-ready callback with typed delivery**

Keep compatibility during migration:

```swift
public var onBundleReady: (([URL]) -> Void)?
public var onBundleReadyDelivery: ((OperationBundleReadyDelivery) -> Void)?
```

When completing an operation with bundles, call:

```swift
let delivery = OperationBundleReadyDelivery(bundleURLs: bundleURLs, route: item.route)
onBundleReadyDelivery?(delivery)
onBundleReady?(bundleURLs)
```

- [ ] **Step 6: Update AppDelegate completion routing**

In `applicationDidFinishLaunching`, replace the raw `DownloadCenter.shared.onBundleReady` handler with typed delivery:

```swift
DownloadCenter.shared.onBundleReadyDelivery = { [weak self] delivery in
    self?.handleBundleReadyDelivery(delivery)
}
```

Implement:

```swift
private func handleBundleReadyDelivery(_ delivery: OperationBundleReadyDelivery) {
    guard let route = delivery.route else {
        handleMultipleDownloadsSync(delivery.bundleURLs)
        return
    }

    refreshProjectWindows(
        projectURL: route.projectURL,
        selecting: route.autoSelectOutputs ? delivery.bundleURLs.first : nil,
        originScope: route.originWindowStateScope
    )
}
```

- [ ] **Step 7: Run tests**

Run:

```bash
swift test --filter OperationRoutingTests
swift test --filter FASTQOperationDialogRoutingTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/Services/DownloadCenter.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/OperationRoutingTests.swift Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift
git commit -m "feat: route operation completions by project window"
```

---

### Task 8: Centralize Project Filesystem Refresh Fanout

**Files:**
- Create: `Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorTests.swift`

- [ ] **Step 1: Write refresh coordinator tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectFilesystemRefreshCoordinatorTests: XCTestCase {
    func testFanoutDeliversChangesToAllRegisteredSinksForProject() {
        let coordinator = ProjectFilesystemRefreshCoordinator(startWatchers: false)
        let projectURL = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        var leftCount = 0
        var rightCount = 0

        let left = coordinator.register(projectURL: projectURL) { _ in leftCount += 1 }
        let right = coordinator.register(projectURL: projectURL) { _ in rightCount += 1 }

        coordinator.deliverForTesting(projectURL: projectURL, changedPaths: .init(all: [projectURL], nonSidecar: [projectURL]))

        XCTAssertEqual(leftCount, 1)
        XCTAssertEqual(rightCount, 1)

        coordinator.unregister(left)
        coordinator.unregister(right)
    }
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter ProjectFilesystemRefreshCoordinatorTests`

Expected: FAIL because `ProjectFilesystemRefreshCoordinator` does not exist.

- [ ] **Step 3: Implement coordinator**

```swift
@MainActor
public final class ProjectFilesystemRefreshCoordinator {
    public struct Registration: Hashable {
        fileprivate let id: UUID
    }

    private struct ProjectWatch {
        var watcher: FileSystemWatcher?
        var sinks: [UUID: (FileSystemWatcher.ChangedPaths) -> Void]
    }

    private var watches: [URL: ProjectWatch] = [:]
    private let startWatchers: Bool

    public init(startWatchers: Bool = true) {
        self.startWatchers = startWatchers
    }

    public func register(projectURL: URL, sink: @escaping (FileSystemWatcher.ChangedPaths) -> Void) -> Registration {
        let canonical = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        let id = UUID()
        var watch = watches[canonical] ?? ProjectWatch(watcher: nil, sinks: [:])
        watch.sinks[id] = sink

        if watch.watcher == nil && startWatchers {
            let watcher = FileSystemWatcher { [weak self] changedPaths in
                MainActor.assumeIsolated {
                    self?.deliver(projectURL: canonical, changedPaths: changedPaths)
                }
            }
            watcher.startWatching(directory: canonical)
            watch.watcher = watcher
        }

        watches[canonical] = watch
        return Registration(id: id)
    }

    public func unregister(_ registration: Registration) {
        for key in watches.keys {
            watches[key]?.sinks.removeValue(forKey: registration.id)
            if watches[key]?.sinks.isEmpty == true {
                watches[key]?.watcher?.stopWatching()
                watches.removeValue(forKey: key)
            }
        }
    }

    private func deliver(projectURL: URL, changedPaths: FileSystemWatcher.ChangedPaths) {
        watches[projectURL]?.sinks.values.forEach { $0(changedPaths) }
    }

    func deliverForTesting(projectURL: URL, changedPaths: FileSystemWatcher.ChangedPaths) {
        deliver(projectURL: ProjectSessionRegistry.canonicalProjectURL(projectURL), changedPaths: changedPaths)
    }
}
```

- [ ] **Step 4: Register sidebars through the coordinator**

Move watcher ownership out of `SidebarViewController.openProject(at:)`. The sidebar should expose:

```swift
public func applyProjectFilesystemChange(_ changedPaths: FileSystemWatcher.ChangedPaths) {
    if changedPaths.nonSidecar.isEmpty && !changedPaths.all.isEmpty {
        updateSearchIndex(changedPaths: changedPaths.all)
    } else if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
        reloadFromFilesystem()
    } else {
        updateSidebar(changedPaths: changedPaths)
    }
}
```

Register each window/sidebar in `AppDelegate` or `MainSplitViewController` when a project session opens.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter ProjectFilesystemRefreshCoordinatorTests
swift test --filter SidebarViewControllerSelectionTests
swift test --filter FileSystemWatcherTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorTests.swift
git commit -m "refactor: fan out project filesystem refreshes"
```

---

### Task 9: Add User-Facing Same-Project Window Affordances

**Files:**
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Test: `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
- Test: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Add menu accessibility test**

```swift
func testWindowMenuIncludesNewWindowForCurrentProject() throws {
    let mainMenu = MainMenu.createMainMenu()
    let windowMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Window" })?.submenu)
    let item = try XCTUnwrap(windowMenu.items.first(where: { $0.title == "New Window for Current Project" }))
    XCTAssertEqual(item.action, #selector(AppDelegate.newWindowForCurrentProject(_:)))
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter AppShellAccessibilityTests/testWindowMenuIncludesNewWindowForCurrentProject`

Expected: FAIL because the menu item does not exist.

- [ ] **Step 3: Add the menu item**

In `MainMenu.createWindowMenu()`, add:

```swift
windowMenu.addItem(
    withTitle: "New Window for Current Project",
    action: #selector(AppDelegate.newWindowForCurrentProject(_:)),
    keyEquivalent: "n"
).keyEquivalentModifierMask = [.command, .option]
```

- [ ] **Step 4: Implement `newWindowForCurrentProject(_:)`**

```swift
@IBAction func newWindowForCurrentProject(_ sender: Any?) {
    guard let source = targetMainWindowController(sender: sender),
          let projectURL = source.projectSession.projectURL else { return }

    let session = ProjectSession()
    let controller = createAndShowMainWindow(projectSession: session)
    NSApp.activate()
    openProject(projectURL, in: controller)
}
```

- [ ] **Step 5: Add title numbering helper**

In `AppDelegate`, after registering a project session, update the window title:

```swift
private func updateProjectWindowTitle(_ controller: MainWindowController) {
    guard let projectURL = controller.projectSession.projectURL else {
        controller.window?.title = "Lungfish Genome Explorer"
        return
    }
    let projectName = projectURL.deletingPathExtension().lastPathComponent
    let number = projectSessionRegistry.windowNumber(for: controller.projectSession)
    let suffix = controller.projectSession.openWarningState.isReadOnlyRecommended ? " (Read Only)" : ""
    controller.window?.title = "\(projectName) [\(number)]\(suffix) - Lungfish Genome Explorer"
}
```

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter AppShellAccessibilityTests
swift test --filter MainWindowSessionRoutingTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/App/MainMenu.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/Views/MainWindow/MainWindowController.swift Tests/LungfishAppTests/AppShellAccessibilityTests.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "feat: add same-project window affordance"
```

---

### Task 10: Enforce Read-Only UI for External Project Locks

**Files:**
- Modify: `Sources/LungfishApp/StateManagement/ProjectSession.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/ProjectSessionTests.swift`
- Test: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Add read-only tests**

```swift
func testSessionReportsReadOnlyWhenExternalLockIsActive() throws {
    let projectURL = tempRoot.appendingPathComponent("Locked.lungfish", isDirectory: true)
    _ = try DocumentManager.shared.createProject(at: projectURL, name: "Locked")
    let lockURL = ProjectLockManager.lockURL(for: projectURL)
    let record = ProjectLockRecord(
        schemaVersion: 1,
        toolName: "external tool",
        appVersion: "1.0",
        projectPath: projectURL.path,
        mode: "exclusive",
        user: NSUserName(),
        host: "other-host.example",
        pid: 999999,
        processStartTime: "Mon May 11 12:00:00 2026",
        cwd: FileManager.default.currentDirectoryPath,
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
    try ProjectLockManager().writeLock(record, to: lockURL)

    let session = ProjectSession()
    try session.openProject(at: projectURL)

    XCTAssertTrue(session.isReadOnlyRecommended)
}
```

- [ ] **Step 2: Run the failing test**

Run: `swift test --filter ProjectSessionTests/testSessionReportsReadOnlyWhenExternalLockIsActive`

Expected: FAIL because `isReadOnlyRecommended` does not exist.

- [ ] **Step 3: Add read-only computed state**

In `ProjectSession`:

```swift
public var isReadOnlyRecommended: Bool {
    openWarningState.isReadOnlyRecommended
}
```

- [ ] **Step 4: Gate project-mutating menu actions**

In `validateMenuItem(_:)`, disable imports, transformations, project temp clearing, and in-project writes when the target session is read-only:

```swift
if let session = targetProjectSession(sender: menuItem), session.isReadOnlyRecommended {
    if ProjectMutationMenuActions.contains(menuItem.action) {
        return false
    }
}
```

Define `ProjectMutationMenuActions` as an internal helper with concrete selectors for import, mapping, assembly, classifier, extraction, and project temp cleanup actions.

- [ ] **Step 5: Add banner hook**

In `MainSplitViewController.applyProjectSessionState()`, if `projectSession.openWarningState.warningMessage` is non-nil, show a persistent top-of-workspace warning strip. Reuse existing native labels/buttons, with a `View Lock Details` button that opens an `NSAlert` sheet.

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter ProjectSessionTests
swift test --filter MainWindowSessionRoutingTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/StateManagement/ProjectSession.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/ProjectSessionTests.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "feat: enforce read-only project lock state"
```

---

### Task 11: Preserve Provenance and Currentness Across Windows

**Files:**
- Modify: operation launch paths touched by Task 7
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: extend provenance-related app tests nearest the touched workflow

- [ ] **Step 1: Add launch-context assertions to existing operation tests**

Extend focused tests so GUI-originated operations assert:

```swift
XCTAssertEqual(captured.route?.projectURL, expectedProjectURL.standardizedFileURL)
XCTAssertEqual(captured.route?.originWindowStateScope, expectedWindowScope)
XCTAssertTrue(captured.provenanceInputs.allSatisfy { !$0.path.contains("/tmp/") || $0.path.contains(expectedProjectURL.path) })
```

- [ ] **Step 2: Snapshot operation inputs at launch**

For FASTQ derivatives, taxonomy extraction, mapping, assembly, and classifier launch paths, capture:

- canonical project URL,
- origin window scope,
- selected bundle URL,
- selected stable dataset IDs when available,
- input file sizes and checksums,
- selected options and resolved defaults,
- expected final output bundle URL.

- [ ] **Step 3: Revalidate before publish**

Before final bundle publish, compare captured input file sizes/checksums against current files. If they changed, fail the operation with an actionable error and leave temporary outputs outside the project-visible tree.

- [ ] **Step 4: Ensure final-payload provenance**

For each touched workflow, assert provenance paths point at final stored bundle payloads after import, not temporary staging files. Use existing Lungfish provenance writers rather than adding ad hoc sidecar formats.

- [ ] **Step 5: Run focused provenance tests**

Run the tests nearest each touched workflow, including:

```bash
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter FASTQProjectSimulationTests
swift test --filter TaxonomyViewControllerTests
swift test --filter MappingProvenanceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift Tests/LungfishAppTests Tests/LungfishWorkflowTests
git commit -m "fix: preserve routed provenance for project window operations"
```

---

### Task 12: Add Same-Project Multi-Window XCUITest Smoke

**Files:**
- Modify: `Tests/LungfishXCUITests/ProjectLifecycleXCUITests.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/ProjectLifecycleRobot.swift` or nearest robot file

- [ ] **Step 1: Add the smoke test**

```swift
@MainActor
func testSameProjectCanOpenInTwoWindowsWithIndependentSelections() throws {
    let projectURL = try makeProjectFixture(named: "SameProjectTwoWindows")
    let robot = ProjectLifecycleRobot()
    defer { robot.app.terminate() }

    robot.launch(openingProject: projectURL)
    XCTAssertTrue(robot.projectWindow(for: projectURL, index: 1).waitForExistence(timeout: 10))

    robot.openNewWindowForCurrentProject()
    XCTAssertTrue(robot.projectWindow(for: projectURL, index: 2).waitForExistence(timeout: 10))

    robot.selectSidebarItem(named: "Analyses", inWindowIndex: 1)
    robot.selectSidebarItem(named: "Reference Sequences", inWindowIndex: 2)

    XCTAssertTrue(robot.sidebarItem(named: "Analyses", inWindowIndex: 1).isSelected)
    XCTAssertTrue(robot.sidebarItem(named: "Reference Sequences", inWindowIndex: 2).isSelected)
}
```

- [ ] **Step 2: Run the failing XCUITest**

Run:

```bash
xcodebuild test -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/ProjectLifecycleXCUITests/testSameProjectCanOpenInTwoWindowsWithIndependentSelections
```

Expected: FAIL until robot helpers and UI affordance are wired.

- [ ] **Step 3: Add robot helpers**

Implement:

```swift
func openNewWindowForCurrentProject() {
    app.menuBars.menuItems["Window"].menus.menuItems["New Window for Current Project"].click()
}

func projectWindow(for projectURL: URL, index: Int) -> XCUIElement {
    let projectName = projectURL.deletingPathExtension().lastPathComponent
    return app.windows["\(projectName) [\(index)] - Lungfish Genome Explorer"]
}
```

Use existing robot conventions for selectors and waits.

- [ ] **Step 4: Run XCUITest**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishXCUITests/ProjectLifecycleXCUITests.swift Tests/LungfishXCUITests/TestSupport
git commit -m "test: cover same-project multi-window smoke"
```

---

### Task 13: Final Verification and Audit

**Files:**
- No planned source edits unless verification reveals a defect.

- [ ] **Step 1: Run global project-state audit**

Run:

```bash
rg -n "DocumentManager\\.shared\\.(activeProject|activeDocument|documents)|mainWindowController\\?" Sources/LungfishApp/App Sources/LungfishApp/Views Sources/LungfishApp/Services
```

Expected: remaining matches are documented compatibility paths or non-project UI paths. No project mutation or operation completion path depends on stale global active state.

- [ ] **Step 2: Run targeted unit tests**

Run:

```bash
swift test --filter ProjectSessionTests
swift test --filter ProjectSessionRegistryTests
swift test --filter MainWindowSessionRoutingTests
swift test --filter NotificationProjectScopeTests
swift test --filter OperationRoutingTests
swift test --filter ProjectFilesystemRefreshCoordinatorTests
swift test --filter FASTQOperationDialogRoutingTests
```

Expected: PASS.

- [ ] **Step 3: Run broader app tests touched by routing**

Run:

```bash
swift test --filter LungfishAppTests
```

Expected: PASS.

- [ ] **Step 4: Run XCUITest smoke**

Run:

```bash
xcodebuild test -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/ProjectLifecycleXCUITests/testSameProjectCanOpenInTwoWindowsWithIndependentSelections
```

Expected: PASS, or record exact environment limitation.

- [ ] **Step 5: Run full Swift test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit final fixes**

```bash
git status --short
git add <files changed by verification fixes>
git commit -m "test: verify same-project multi-window support"
```

Skip this commit if verification required no changes.

---

## Self-Review

- Spec coverage: tasks cover session state, duplicate-window UX, notification scoping, operation routing, filesystem refresh, read-only lock behavior, provenance/currentness, and tests.
- Placeholder scan: no implementation step depends on unspecified file paths or unnamed tests.
- Type consistency: `ProjectSession`, `ProjectSessionRegistry`, `WindowStateScope`, `OperationRoute`, and `OperationBundleReadyDelivery` are named consistently across tasks.
- Provenance: the plan explicitly blocks success presentation for new scientific outputs with missing or staging-path provenance.
