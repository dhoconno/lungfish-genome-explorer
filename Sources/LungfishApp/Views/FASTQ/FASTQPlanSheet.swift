// FASTQPlanSheet.swift - The sheet that writes a plan for a Linux machine or cluster (CHTC C4 lane U, C4-12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow

/// What the plan sheet hands its caller: the `import fastq --write-plan` argv and the folder it writes.
struct FASTQPlanSheetRequest: Sendable, Equatable {
    let arguments: [String]
    let planFolder: URL
}

/// The sheet that writes the files a Linux machine or cluster runs to pre-process the chosen reads: one plan folder a
/// sample, HTCondor's `sample.sub` and `run.dag`, and the list of files to copy to the staging folder. The result comes
/// back to this Mac through Linux Run Result in the Import Center.
///
/// It keeps the Import sheet's Optimize storage box and Compression Tool popup with the plan's defaults (C4-12,
/// UX-XC26). It looks for the executor folder when it opens, and a build without one keeps the sheet open with the
/// write button disabled and UX's sentence after the clumping controls.
@MainActor
final class FASTQPlanSheet: NSViewController {
    private let inputs: [URL]
    let executorManifest: URL?
    private let imageFiles: (image: URL, toolManifest: URL)?
    private let chooseFolder: @MainActor (NSWindow?, @escaping @MainActor (URL?) -> Void) -> Void
    private let onWrite: (@MainActor (FASTQPlanSheetRequest) -> Void)?
    private let onCancel: (@MainActor () -> Void)?

    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let stagingField = NSTextField(string: "")
    let threadsField = NSTextField(string: String(FASTQPlanSheetModel.defaultThreads))
    let heapField = NSTextField(string: String(FASTQPlanSheetModel.defaultClumpifyHeapGB))
    let clumpifyCheckbox = NSButton(
        checkboxWithTitle: "Optimize storage (reorder reads for better compression)", target: nil, action: nil
    )
    let clumpingToolLabel = NSTextField(labelWithString: "Compression Tool:")
    let clumpingToolPopup = NSPopUpButton()
    let clumpingToolLineLabel = NSTextField(wrappingLabelWithString: "")
    let noExecutorLabel = NSTextField(wrappingLabelWithString: FASTQPlanSheetModel.noExecutorSentence)
    let writeButton = NSButton(title: FASTQPlanSheetModel.writeButtonTitle, target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// - Parameters:
    ///   - inputs: The read files, or one folder whose top level holds them, as `import fastq` takes them.
    ///   - executorFolder: The folder that should hold `lungfish-executor` and its `manifest.json`.
    ///   - chooseFolder: Asks for the new plan folder; the default is a save panel on the sheet.
    init(
        inputs: [URL],
        executorFolder: URL? = FASTQPlanSheetModel.bundledExecutorFolder(),
        imageFiles: (image: URL, toolManifest: URL)? = FASTQPlanSheetModel.bundledImageFiles(),
        chooseFolder: (@MainActor (NSWindow?, @escaping @MainActor (URL?) -> Void) -> Void)? = nil,
        onWrite: (@MainActor (FASTQPlanSheetRequest) -> Void)? = nil,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        self.inputs = inputs
        self.executorManifest = FASTQPlanSheetModel.executorManifest(inFolder: executorFolder)
        self.imageFiles = imageFiles
        self.chooseFolder = chooseFolder ?? FASTQPlanSheet.chooseFolderWithSavePanel
        self.onWrite = onWrite
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        let header = NSTextField(labelWithString: FASTQPlanSheetModel.title)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        summaryLabel.stringValue = inputs.count == 1
            ? "Reads: \(inputs[0].lastPathComponent)"
            : "Reads: \(inputs.count) files"
        stagingField.placeholderString = "/path/on/the/linux/machine"
        stagingField.setAccessibilityLabel("Staging folder")
        let stagingHelp = Self.secondaryLabel(FASTQPlanSheetModel.stagingHelp)
        threadsField.setAccessibilityLabel("Threads per job")
        heapField.setAccessibilityLabel("Clumpify memory in GB")
        clumpifyCheckbox.state = FASTQPlanSheetModel.defaultOptimizeStorage ? .on : .off
        clumpifyCheckbox.target = self
        clumpifyCheckbox.action = #selector(clumpingControlsChanged(_:))
        for tool in FASTQPlanSheetModel.clumpingToolChoices {
            clumpingToolPopup.addItem(withTitle: tool.displayName)
            clumpingToolPopup.lastItem?.representedObject = tool
        }
        clumpingToolPopup.selectItem(at: 0)
        clumpingToolPopup.target = self
        clumpingToolPopup.action = #selector(clumpingControlsChanged(_:))
        clumpingToolLineLabel.font = .systemFont(ofSize: 11)
        clumpingToolLineLabel.textColor = .secondaryLabelColor
        clumpingToolLineLabel.setAccessibilityIdentifier("fastq-plan-clumping-tool-line")
        noExecutorLabel.font = .systemFont(ofSize: 11)
        noExecutorLabel.textColor = .secondaryLabelColor
        noExecutorLabel.isHidden = executorManifest != nil
        noExecutorLabel.setAccessibilityIdentifier("fastq-plan-no-executor")
        for field in [stagingField, threadsField, heapField] {
            field.target = self
            field.action = #selector(fieldsChanged(_:))
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldsChanged(_:)), name: NSControl.textDidChangeNotification, object: field
            )
        }
        writeButton.bezelStyle = .rounded
        writeButton.keyEquivalent = "\r"
        writeButton.target = self
        writeButton.action = #selector(writeClicked(_:))
        if executorManifest == nil { writeButton.setAccessibilityHelp(FASTQPlanSheetModel.noExecutorSentence) }
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Staging folder:"), stagingField],
            [NSGridCell.emptyContentView, stagingHelp],
            [NSTextField(labelWithString: "Threads per job:"), threadsField],
            [NSTextField(labelWithString: "Clumpify memory (GB):"), heapField],
            [NSGridCell.emptyContentView, clumpifyCheckbox],
            [clumpingToolLabel, clumpingToolPopup],
            [NSGridCell.emptyContentView, clumpingToolLineLabel],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let buttons = NSStackView(views: [NSView(), cancelButton, writeButton])
        buttons.orientation = .horizontal
        // VoiceOver reads the sheet top to bottom: the clumping controls, UX's sentence, then the buttons (UX 5).
        let stack = NSStackView(views: [header, summaryLabel, grid, noExecutorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stagingField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            threadsField.widthAnchor.constraint(equalToConstant: 80),
            heapField.widthAnchor.constraint(equalToConstant: 80),
            noExecutorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            clumpingToolLineLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stagingHelp.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        updateControls()
    }

    private static func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    var selectedClumpingTool: ClumpingTool {
        clumpingToolPopup.selectedItem?.representedObject as? ClumpingTool ?? FASTQPlanSheetModel.defaultClumpingTool
    }

    /// The command the sheet would run now, or nil while a field does not hold a value the command takes.
    func request(planFolder: URL) -> FASTQPlanSheetRequest? {
        guard let executorManifest, let imageFiles, !inputs.isEmpty,
              FASTQPlanSheetModel.isStagingFolder(stagingField.stringValue),
              let threads = FASTQPlanSheetModel.positiveWholeNumber(threadsField.stringValue),
              let heap = FASTQPlanSheetModel.positiveWholeNumber(heapField.stringValue) else { return nil }
        let arguments = FASTQPlanSheetModel.cliArguments(
            inputs: inputs, planFolder: planFolder, executorManifest: executorManifest, image: imageFiles.image,
            imageToolManifest: imageFiles.toolManifest, stagingFolder: stagingField.stringValue, threads: threads,
            clumpifyHeapGB: heap, optimizeStorage: clumpifyCheckbox.state == .on, tool: selectedClumpingTool
        )
        return FASTQPlanSheetRequest(arguments: arguments, planFolder: planFolder)
    }

    private func updateControls() {
        let optimizeStorage = clumpifyCheckbox.state == .on
        clumpingToolLabel.isEnabled = optimizeStorage
        clumpingToolPopup.isEnabled = optimizeStorage
        let line = FASTQPlanSheetModel.lineUnderPopup(optimizeStorage: optimizeStorage, tool: selectedClumpingTool)
        clumpingToolLineLabel.stringValue = line ?? ""
        clumpingToolLineLabel.isHidden = line == nil
        writeButton.isEnabled = request(planFolder: URL(fileURLWithPath: "/")) != nil
    }

    @objc private func clumpingControlsChanged(_ sender: Any) { updateControls() }

    @objc private func fieldsChanged(_ sender: Any) { updateControls() }

    @objc func writeClicked(_ sender: Any?) {
        // A build with no executor writes nothing, neither a plan folder nor a staging list (UX 6).
        guard executorManifest != nil, request(planFolder: URL(fileURLWithPath: "/")) != nil else { return }
        chooseFolder(view.window) { [weak self] folder in
            guard let self, let folder, let request = self.request(planFolder: folder) else { return }
            self.onWrite?(request)
            self.dismissSheet()
        }
    }

    @objc private func cancelClicked(_ sender: Any) {
        onCancel?()
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    private static func chooseFolderWithSavePanel(_ window: NSWindow?, _ done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.message = FASTQPlanSheetModel.chooserMessage
        panel.prompt = "Write Plan"
        panel.nameFieldStringValue = "lungfish-plan"
        panel.canCreateDirectories = true
        // The panel runs app-modal over the sheet, so its answer arrives on the main actor with no escape hatch.
        done(panel.runModal() == .OK ? panel.url : nil)
    }

    /// Presents the sheet on `window`.
    static func present(on window: NSWindow, inputs: [URL], onWrite: @escaping @MainActor (FASTQPlanSheetRequest) -> Void) {
        let sheet = FASTQPlanSheet(inputs: inputs, onWrite: onWrite)
        let sheetWindow = NSWindow(contentViewController: sheet)
        sheetWindow.title = FASTQPlanSheetModel.title
        window.beginSheet(sheetWindow)
    }
}
