import AppKit
import Combine
import LungfishIO
import LungfishWorkflow
import SwiftUI

@MainActor
final class HaplotypeDefinitionManagerWindowController: NSWindowController {
    private static var shared: HaplotypeDefinitionManagerWindowController?

    static func show(projectURL: URL?) {
        let controller = shared ?? HaplotypeDefinitionManagerWindowController(projectURL: projectURL)
        shared = controller
        if let view = controller.window?.contentViewController as? NSHostingController<HaplotypeDefinitionManagerView> {
            view.rootView.viewModel.configure(projectURL: projectURL)
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
    var definition: GenotypeHaplotypeDefinitionSet
}

@MainActor
final class HaplotypeDefinitionManagerViewModel: ObservableObject {
    @Published private(set) var projectURL: URL?
    @Published private(set) var records: [HaplotypeDefinitionRecord] = []
    @Published var selectedRecordID: String?
    @Published var errorMessage: String?

    private var globalRoot: URL

    init(projectURL: URL?) {
        self.projectURL = projectURL?.standardizedFileURL
        self.globalRoot = HaplotypeDefinitionLibrary.defaultGlobalRoot()
        reload()
    }

    func configure(projectURL: URL?) {
        self.projectURL = projectURL?.standardizedFileURL
        reload()
    }

    var selectedRecord: HaplotypeDefinitionRecord? {
        records.first { $0.id == selectedRecordID } ?? records.first
    }

    var canWriteProjectDefinitions: Bool {
        projectURL != nil
    }

    func reload() {
        records = service.listDefinitions(includeShadowed: true)
        if selectedRecordID == nil || records.contains(where: { $0.id == selectedRecordID }) == false {
            selectedRecordID = records.first?.id
        }
    }

    func newDraft(scope: HaplotypeDefinitionScope) -> HaplotypeDefinitionManagerEditingDraft {
        HaplotypeDefinitionManagerEditingDraft(
            scope: scope,
            originalDefinitionID: nil,
            isReadOnly: false,
            allowsIdentityEditing: true,
            definition: Self.templateDefinition()
        )
    }

    func editDraft(for record: HaplotypeDefinitionRecord) -> HaplotypeDefinitionManagerEditingDraft {
        HaplotypeDefinitionManagerEditingDraft(
            scope: record.scope,
            originalDefinitionID: record.definitionSet.id,
            isReadOnly: record.scope == .builtIn,
            allowsIdentityEditing: false,
            definition: record.definitionSet
        )
    }

    func importDefinition(scope: HaplotypeDefinitionScope) {
        let panel = NSOpenPanel()
        panel.title = "Import Haplotype Definition"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            _ = try service.importDefinition(
                from: url,
                scope: scope,
                changeNote: "Imported from Haplotype Definition Manager",
                argv: ["lungfish", "haplotypes", "import", url.path, "--scope", scope.rawValue]
            )
        }
    }

    func exportSelected() {
        guard let record = selectedRecord else { return }
        let panel = NSSavePanel()
        panel.title = "Export Haplotype Definition"
        panel.nameFieldStringValue = "\(record.definitionSet.id)\(HaplotypeDefinitionStore.fileSuffix)"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try service.exportDefinition(
                definitionID: record.definitionSet.id,
                assayID: record.definitionSet.assayID,
                scope: record.scope,
                to: url,
                argv: ["lungfish", "haplotypes", "export", record.definitionSet.id, "--output", url.path]
            )
        }
    }

    func duplicateSelected(to scope: HaplotypeDefinitionScope) {
        guard let record = selectedRecord else { return }
        perform {
            _ = try service.duplicateDefinition(
                definitionID: record.definitionSet.id,
                assayID: record.definitionSet.assayID,
                fromScope: record.scope,
                toScope: scope,
                changeNote: "Duplicated from \(record.scope.displayName)",
                argv: [
                    "lungfish", "haplotypes", "duplicate", record.definitionSet.id,
                    "--source-scope", record.scope.rawValue,
                    "--target-scope", scope.rawValue,
                ]
            )
        }
    }

    func deleteSelected() {
        guard let record = selectedRecord, record.scope != .builtIn else { return }
        perform {
            try service.deleteDefinition(
                definitionID: record.definitionSet.id,
                scope: record.scope,
                argv: ["lungfish", "haplotypes", "delete", record.definitionSet.id, "--scope", record.scope.rawValue]
            )
        }
    }

    func saveDraft(_ draft: HaplotypeDefinitionManagerEditingDraft) {
        let definitionPath = definitionURL(for: draft.definition.id, scope: draft.scope)?.path
            ?? draft.definition.id
        perform {
            _ = try service.saveDefinition(
                draft.definition,
                scope: draft.scope,
                changeNote: draft.originalDefinitionID == nil
                    ? "Created in Haplotype Definition Manager"
                    : "Edited in Haplotype Definition Manager",
                argv: cliArgv(
                    ["haplotypes", "save", definitionPath, "--scope", draft.scope.rawValue],
                    scope: draft.scope
                )
            )
        }
    }

    private var service: HaplotypeDefinitionCommandService {
        HaplotypeDefinitionCommandService(projectRoot: projectURL, globalRoot: globalRoot)
    }

    private func definitionURL(for id: String, scope: HaplotypeDefinitionScope) -> URL? {
        switch scope {
        case .builtIn:
            return nil
        case .global:
            return HaplotypeDefinitionStore(projectRoot: globalRoot).definitionURL(for: id)
        case .project:
            return HaplotypeDefinitionStore(projectRoot: projectURL).definitionURL(for: id)
        }
    }

    private func cliArgv(_ arguments: [String], scope: HaplotypeDefinitionScope) -> [String] {
        var argv = ["lungfish"] + arguments
        if scope == .project, let projectURL {
            argv += ["--project", projectURL.path]
        }
        if scope == .global {
            argv += ["--global-root", globalRoot.path]
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
                onSave: { saved in
                    var updatedDraft = draft
                    updatedDraft.definition = saved
                    viewModel.saveDraft(updatedDraft)
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
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                editingDraft = viewModel.newDraft(scope: viewModel.canWriteProjectDefinitions ? .project : .global)
            } label: {
                Label("New", systemImage: "plus")
            }
            Menu {
                if viewModel.canWriteProjectDefinitions {
                    Button("Project") { viewModel.importDefinition(scope: .project) }
                }
                Button("Global") { viewModel.importDefinition(scope: .global) }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            Button {
                viewModel.exportSelected()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.selectedRecord == nil)
            Spacer()
            Button {
                viewModel.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
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
                Text(record.scope.displayName)
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
                    detailRow("Source", record.scope.displayName)
                    detailRow("Loci", record.definitionSet.locusDefinitions.map(\.locus).joined(separator: ", "))
                }
                Divider()
                HStack(spacing: 8) {
                    Button(record.scope == .builtIn ? "View" : "Edit") {
                        editingDraft = viewModel.editDraft(for: record)
                    }
                    if viewModel.canWriteProjectDefinitions {
                        Button("Duplicate to Project") {
                            viewModel.duplicateSelected(to: .project)
                        }
                    }
                    Button("Duplicate to Global") {
                        viewModel.duplicateSelected(to: .global)
                    }
                    Button("Delete") {
                        viewModel.deleteSelected()
                    }
                    .foregroundStyle(Color.lungfishDangerFallback)
                    .tint(Color.lungfishDangerFallback)
                    .disabled(record.scope == .builtIn)
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
