import AppKit
import Combine
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HaplotypeDefinitionManagerWindowController: NSWindowController {
    private static var shared: HaplotypeDefinitionManagerWindowController?

    static func show(projectURL: URL?) {
        show(projectURL: projectURL, editingBundleURL: nil)
    }

    static func show(projectURL: URL?, editingBundleURL: URL?) {
        let controller = shared ?? HaplotypeDefinitionManagerWindowController(projectURL: projectURL)
        shared = controller
        if let view = controller.window?.contentViewController as? NSHostingController<HaplotypeDefinitionManagerView> {
            view.rootView.viewModel.configure(
                projectURL: projectURL,
                editingBundleURL: editingBundleURL
            )
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(projectURL: URL?) {
        let viewModel = HaplotypeDefinitionManagerViewModel(projectURL: projectURL)
        let rootView = HaplotypeDefinitionManagerView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Haplotype Definitions"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct HaplotypeDefinitionManagerEditingDraft: Identifiable {
    let id = UUID()
    let scope: HaplotypeDefinitionScope
    let originalDefinitionID: String?
    let isReadOnly: Bool
    let allowsIdentityEditing: Bool
    let definitionURL: URL?
    let referenceBundleURL: URL?
    let referenceFASTAURL: URL?
    var definition: GenotypeHaplotypeDefinitionSet
}

@MainActor
final class HaplotypeDefinitionManagerViewModel: ObservableObject {
    @Published private(set) var projectURL: URL?
    @Published private(set) var records: [HaplotypeDefinitionRecord] = []
    @Published var selectedRecordID: String?
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published var pendingEditRecordID: String?

    init(projectURL: URL?) {
        self.projectURL = projectURL?.standardizedFileURL
        reload()
    }

    func configure(projectURL: URL?) {
        configure(projectURL: projectURL, editingBundleURL: nil)
    }

    func configure(projectURL: URL?, editingBundleURL: URL?) {
        self.projectURL = projectURL?.standardizedFileURL
        reload()
        if let editingBundleURL {
            beginEditing(bundleURL: editingBundleURL)
        }
    }

    var selectedRecord: HaplotypeDefinitionRecord? {
        records.first { $0.id == selectedRecordID } ?? records.first
    }

    var canWriteProjectDefinitions: Bool {
        projectURL != nil
    }

    func reload() {
        records = service.listDefinitions(includeShadowed: true, includeReferenceBundles: true)
        if selectedRecordID == nil || records.contains(where: { $0.id == selectedRecordID }) == false {
            selectedRecordID = records.first?.id
        }
    }

    func newDraft() -> HaplotypeDefinitionManagerEditingDraft {
        HaplotypeDefinitionManagerEditingDraft(
            scope: .project,
            originalDefinitionID: nil,
            isReadOnly: false,
            allowsIdentityEditing: true,
            definitionURL: nil,
            referenceBundleURL: nil,
            referenceFASTAURL: nil,
            definition: Self.templateDefinition()
        )
    }

    func editDraft(for record: HaplotypeDefinitionRecord) -> HaplotypeDefinitionManagerEditingDraft {
        HaplotypeDefinitionManagerEditingDraft(
            scope: record.scope,
            originalDefinitionID: record.definitionSet.id,
            isReadOnly: false,
            allowsIdentityEditing: false,
            definitionURL: record.fileURL,
            referenceBundleURL: record.referenceBundleURL,
            referenceFASTAURL: record.referenceFASTAURL,
            definition: record.definitionSet
        )
    }

    func beginEditing(bundleURL: URL) {
        let standardized = bundleURL.standardizedFileURL
        guard let record = records.first(where: { $0.referenceBundleURL == standardized }) else {
            errorMessage = "This MHC reference bundle is not available in the active project."
            return
        }
        selectedRecordID = record.id
        pendingEditRecordID = record.id
    }

    func importDefinition() {
        let panel = NSOpenPanel()
        panel.title = "Import Haplotype Definition or Bundle"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
            + [UTType(filenameExtension: MHCAmpliconReferenceBundle.directoryExtension)].compactMap { $0 }
        begin(panel) { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            if MHCAmpliconReferenceBundle.isBundleURL(url) {
                self.importBundle(at: url)
            } else {
                self.perform {
                    _ = try self.service.importDefinition(
                        from: url,
                        scope: .project,
                        changeNote: "Imported from Haplotype Definition Manager",
                        argv: ["lungfish-cli", "haplotypes", "import", url.path, "--scope", HaplotypeDefinitionScope.project.rawValue]
                    )
                }
            }
        }
    }

    /// Installs an existing `.lungfishmhcref` bundle into the project, reloads the
    /// list, and selects the newly installed bundle's record. Exposed (not behind
    /// the NSOpenPanel) so the install + reload + select behavior is unit testable.
    func importBundle(at url: URL) {
        do {
            let installed = try service.installMHCReferenceBundle(
                from: url,
                argv: ["lungfish-cli", "haplotypes", "bundle-install", url.path]
            )
            reload()
            selectedRecordID = records.first {
                $0.referenceBundleURL == installed.standardizedFileURL
            }?.id ?? selectedRecordID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSelected() {
        guard let record = selectedRecord else { return }
        let panel = NSSavePanel()
        panel.title = "Export Haplotype Definition"
        panel.nameFieldStringValue = "\(record.definitionSet.id)\(HaplotypeDefinitionStore.fileSuffix)"
        panel.allowedContentTypes = [.json]
        begin(panel) { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            self.perform {
                try self.service.exportDefinition(
                    definitionID: record.definitionSet.id,
                    assayID: record.definitionSet.assayID,
                    scope: record.scope,
                    to: url,
                    argv: ["lungfish-cli", "haplotypes", "export", record.definitionSet.id, "--output", url.path]
                )
            }
        }
    }

    func duplicateSelectedToProject() {
        guard let record = selectedRecord else { return }
        perform {
            if record.referenceBundleURL != nil {
                _ = try service.saveDefinition(
                    record.definitionSet,
                    scope: .project,
                    changeNote: "Duplicated from MHC reference bundle",
                    argv: cliArgv(
                        ["haplotypes", "save", record.definitionSet.id, "--scope", HaplotypeDefinitionScope.project.rawValue]
                    )
                )
            } else {
                _ = try service.duplicateDefinition(
                    definitionID: record.definitionSet.id,
                    assayID: record.definitionSet.assayID,
                    fromScope: record.scope,
                    toScope: .project,
                    changeNote: "Duplicated from \(record.scope.displayName)",
                    argv: [
                        "lungfish-cli", "haplotypes", "duplicate", record.definitionSet.id,
                        "--source-scope", record.scope.rawValue,
                        "--target-scope", HaplotypeDefinitionScope.project.rawValue,
                    ]
                )
            }
        }
    }

    func deleteSelected() {
        guard let record = selectedRecord else { return }
        perform {
            try service.deleteDefinition(
                definitionID: record.definitionSet.id,
                scope: record.scope,
                argv: ["lungfish-cli", "haplotypes", "delete", record.definitionSet.id, "--scope", record.scope.rawValue]
            )
        }
    }

    /// Persists an edited draft. Every definition is a `.lungfishmhcref`
    /// bundle: editing an existing bundle updates the embedded definition (and
    /// optionally replaces its reference FASTA), while a new definition builds
    /// a fresh bundle from the chosen reference FASTA. There is no bare-def
    /// write path from the editor.
    func saveDraft(
        _ draft: HaplotypeDefinitionManagerEditingDraft,
        referenceFASTA: URL?
    ) {
        if let bundleURL = draft.referenceBundleURL {
            saveDraftIntoExistingBundle(draft, bundleURL: bundleURL, referenceFASTA: referenceFASTA)
        } else {
            createBundleForNewDraft(draft, referenceFASTA: referenceFASTA)
        }
    }

    private func saveDraftIntoExistingBundle(
        _ draft: HaplotypeDefinitionManagerEditingDraft,
        bundleURL: URL,
        referenceFASTA: URL?
    ) {
        perform {
            _ = try service.saveDefinition(
                draft.definition,
                inMHCReferenceBundle: bundleURL,
                changeNote: "Edited in Haplotype Definition Manager",
                argv: [
                    "lungfish-cli", "haplotypes", "bundle-save",
                    draft.definitionURL?.path ?? draft.definition.id,
                    "--bundle", bundleURL.path,
                ]
            )
            if let referenceFASTA,
               referenceFASTA.standardizedFileURL != draft.referenceFASTAURL?.standardizedFileURL {
                _ = try service.replaceReferenceFASTA(
                    inMHCReferenceBundle: bundleURL,
                    with: referenceFASTA,
                    argv: [
                        "lungfish-cli", "haplotypes", "bundle-replace-reference",
                        referenceFASTA.path,
                        "--bundle", bundleURL.path,
                    ]
                )
            }
        }
    }

    private func createBundleForNewDraft(
        _ draft: HaplotypeDefinitionManagerEditingDraft,
        referenceFASTA: URL?
    ) {
        guard let referenceFASTA else {
            errorMessage = "Choose a reference FASTA before saving the definition."
            return
        }
        let outputURL = newBundleDestination(for: draft.definition)
        let record = HaplotypeDefinitionRecord(
            scope: .project,
            assayDisplayName: draft.definition.assayID,
            definitionSet: draft.definition,
            fileURL: draft.definitionURL
        )
        let service = self.service
        let argv = [
            "lungfish-cli", "haplotypes", "bundle-create",
            "--definition", draft.definition.id,
            "--assay", draft.definition.assayID,
            "--species", draft.definition.speciesCode,
            "--scope", HaplotypeDefinitionScope.project.rawValue,
            "--reference-fasta", referenceFASTA.path,
            "--output", outputURL.path,
            "--name", draft.definition.displayName,
            "--default-definition", draft.definition.id,
        ]
        isWorking = true
        // `service` is a non-@MainActor Sendable struct; `record`, referenceFASTA,
        // outputURL, and argv are all Sendable value inputs. The bundle build does
        // heavy synchronous file IO, so it must run off the main thread.
        Task.detached(priority: .userInitiated) {
            let outcome: Result<MHCAmpliconReferenceBundleBuildResult, Error>
            do {
                let result = try await service.createMHCReferenceBundle(
                    records: [record],
                    referenceFASTA: referenceFASTA,
                    outputURL: outputURL,
                    name: draft.definition.displayName,
                    defaultDefinitionID: draft.definition.id,
                    forceOverwrite: false,
                    argv: argv
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            // Hop back to the main actor without `await MainActor.run` (binding rule)
            // using the project's blessed UI-callback pattern.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isWorking = false
                    switch outcome {
                    case .success(let result):
                        self.reload()
                        self.selectedRecordID = self.records.first {
                            $0.referenceBundleURL == result.bundleURL
                                && $0.definitionSet.id == draft.definition.id
                        }?.id ?? self.selectedRecordID
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func replaceReferenceFASTA(for record: HaplotypeDefinitionRecord) {
        guard let bundleURL = record.referenceBundleURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Reference FASTA"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["fa", "fasta", "fna", "gz"].compactMap {
            UTType(filenameExtension: $0)
        }
        begin(panel) { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            self.perform {
                _ = try self.service.replaceReferenceFASTA(
                    inMHCReferenceBundle: bundleURL,
                    with: url,
                    argv: [
                        "lungfish-cli", "haplotypes", "bundle-replace-reference",
                        url.path,
                        "--bundle", bundleURL.path,
                    ]
                )
            }
        }
    }

    func revealReferenceFASTA(for record: HaplotypeDefinitionRecord) {
        guard let url = record.referenceFASTAURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func displayPath(_ url: URL?) -> String {
        guard let url else { return "" }
        if let projectURL {
            let prefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
            if url.path.hasPrefix(prefix) {
                return String(url.path.dropFirst(prefix.count))
            }
        }
        return url.path
    }

    private var service: HaplotypeDefinitionCommandService {
        HaplotypeDefinitionCommandService(projectRoot: projectURL)
    }

    /// Destination for a brand-new definition's `.lungfishmhcref` bundle. Lives
    /// under the project's "Reference allele databases/" directory so it is
    /// discovered by `HaplotypeDefinitionLibrary.records()` (which recursively
    /// scans the project root for bundles), matching the existing
    /// project-bundle creation convention.
    private func newBundleDestination(for definition: GenotypeHaplotypeDefinitionSet) -> URL {
        let baseDirectory = projectURL?
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory
            .appendingPathComponent(safeBundleName(definition.displayName))
            .appendingPathExtension(MHCAmpliconReferenceBundle.directoryExtension)
            .standardizedFileURL
    }

    private func cliArgv(_ arguments: [String]) -> [String] {
        var argv = ["lungfish-cli"] + arguments
        if let projectURL {
            argv += ["--project", projectURL.path]
        }
        return argv
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func begin(_ panel: NSSavePanel, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: parentWindow, completionHandler: completionHandler)
        } else {
            panel.begin(completionHandler: completionHandler)
        }
    }

    private func safeBundleName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._- "))
        let name = String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".-_")))
        return name.isEmpty ? "MHC Reference" : name
    }

    private static func templateDefinition() -> GenotypeHaplotypeDefinitionSet {
        let token = ISO8601DateFormatter()
            .string(from: Date())
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return GenotypeHaplotypeDefinitionSet(
            id: "custom.MHC-exon2-miSeq.\(token)",
            assayID: "MHC-exon2-miSeq",
            displayName: "New haplotype definition",
            speciesName: "Custom macaque",
            speciesCode: "CUSTOM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "New haplotype", diagnosticAlleles: ["replace-with-diagnostic-allele"])
                    ]
                )
            ]
        )
    }
}

struct HaplotypeDefinitionManagerView: View {
    @ObservedObject var viewModel: HaplotypeDefinitionManagerViewModel
    @State private var editingDraft: HaplotypeDefinitionManagerEditingDraft?
    @State private var selectedReferenceURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                definitionList
                    .frame(minWidth: 460)
                detailPane
                    .frame(minWidth: 360)
            }
        }
        .frame(minWidth: 840, minHeight: 520)
        .sheet(item: $editingDraft) { draft in
            GenotypeHaplotypeDefinitionEditor(
                draft: draft.definition,
                isReadOnly: draft.isReadOnly,
                allowsIdentityEditing: draft.allowsIdentityEditing,
                allowsMetadataEditing: true,
                requiresReferenceFASTA: true,
                projectURL: viewModel.projectURL,
                selectedReferenceURL: $selectedReferenceURL,
                onSave: { saved in
                    var updatedDraft = draft
                    updatedDraft.definition = saved
                    viewModel.saveDraft(updatedDraft, referenceFASTA: selectedReferenceURL)
                    editingDraft = nil
                },
                onCancel: {
                    editingDraft = nil
                }
            )
        }
        .alert("Haplotype Definition Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            consumePendingEditRequest()
        }
        .onChange(of: viewModel.pendingEditRecordID) { _, _ in
            consumePendingEditRequest()
        }
    }

    private func beginEditing(_ draft: HaplotypeDefinitionManagerEditingDraft) {
        selectedReferenceURL = draft.referenceFASTAURL
        editingDraft = draft
    }

    private func consumePendingEditRequest() {
        guard let recordID = viewModel.pendingEditRecordID else { return }
        viewModel.pendingEditRecordID = nil
        guard let record = viewModel.records.first(where: { $0.id == recordID }) else { return }
        beginEditing(viewModel.editDraft(for: record))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                beginEditing(viewModel.newDraft())
            } label: {
                Label("New", systemImage: "plus")
            }
            .disabled(!viewModel.canWriteProjectDefinitions)
            Button {
                viewModel.importDefinition()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.canWriteProjectDefinitions)
            Button {
                viewModel.exportSelected()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.selectedRecord == nil || viewModel.selectedRecord?.referenceBundleURL != nil)
            Spacer()
            Button {
                viewModel.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isWorking)
        }
        .padding(10)
    }

    private var definitionList: some View {
        Table(viewModel.records, selection: $viewModel.selectedRecordID) {
            TableColumn("Definition") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.definitionSet.displayName)
                    Text(record.definitionSet.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("Assay") { record in
                Text(record.definitionSet.assayID)
            }
            TableColumn("Species") { record in
                Text(record.definitionSet.speciesCode)
            }
            TableColumn("Source") { record in
                Text(record.sourceDisplayName)
            }
            TableColumn("Status") { record in
                Text(record.isShadowed ? "Shadowed" : "Active")
                    .foregroundStyle(record.isShadowed ? .secondary : .primary)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = viewModel.selectedRecord {
            VStack(alignment: .leading, spacing: 14) {
                Text(record.definitionSet.displayName)
                    .font(.title3.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    detailRow("Definition ID", record.definitionSet.id)
                    detailRow("Assay", record.definitionSet.assayID)
                    detailRow("Species", "\(record.definitionSet.speciesName) (\(record.definitionSet.speciesCode))")
                    detailRow("Source", record.sourceDisplayName)
                    if record.referenceBundleURL != nil {
                        detailRow("Bundle", viewModel.displayPath(record.referenceBundleURL))
                        detailRow("Reference FASTA", viewModel.displayPath(record.referenceFASTAURL))
                    } else {
                        detailRow("Reference FASTA", "Not bundled")
                    }
                    detailRow("Loci", record.definitionSet.locusDefinitions.map(\.locus).joined(separator: ", "))
                }
                Divider()
                HStack(spacing: 8) {
                    Button("Edit") {
                        beginEditing(viewModel.editDraft(for: record))
                    }
                    if record.referenceBundleURL != nil {
                        Button("Replace FASTA...") {
                            viewModel.replaceReferenceFASTA(for: record)
                        }
                        Button("Reveal FASTA") {
                            viewModel.revealReferenceFASTA(for: record)
                        }
                    }
                    if viewModel.canWriteProjectDefinitions {
                        Button("Duplicate to Project") {
                            viewModel.duplicateSelectedToProject()
                        }
                    }
                    Button("Delete") {
                        viewModel.deleteSelected()
                    }
                    .foregroundStyle(Color.lungfishDangerFallback)
                    .tint(Color.lungfishDangerFallback)
                }
                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(16)
        } else {
            ContentUnavailableView("No Haplotype Definition", systemImage: "rectangle.stack")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
