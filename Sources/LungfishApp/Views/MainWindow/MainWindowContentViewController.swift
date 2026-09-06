// MainWindowContentViewController.swift - Main window content wrapper
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class MainWindowContentViewController: NSViewController {
    private let projectSession: ProjectSession
    let splitViewController: MainSplitViewController

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.distribution = .fill
        return stack
    }()

    init(projectSession: ProjectSession, splitViewController: MainSplitViewController) {
        self.projectSession = projectSession
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowContentViewController does not support storyboard initialization")
    }

    override func loadView() {
        view = NSView()
        view.addSubview(stackView)

        addChild(splitViewController)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(splitViewController.view)
        splitViewController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        splitViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitViewController.view.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])

        updateProjectLockWarningBanner()
    }

    func updateProjectLockWarningBanner(with state: ProjectOpenWarningState? = nil) {
        // Lock choices are presented before accepting a project. Read-only state
        // remains visible in the window title without a technical header banner.
    }
}
